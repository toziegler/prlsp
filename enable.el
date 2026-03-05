
;; Emacs integration for the prlsp server.
;; Supports both lsp-mode and eglot backends.

(require 'subr-x)
(require 'seq)
(require 'cl-lib)

(defvar prlsp-preferred-backend 'lsp
  "LSP backend for prlsp auto-start hooks: `lsp' or `eglot'.
Set before this file is loaded.  Both backends are registered
regardless; this only controls which auto-start hooks are added.")

(defvar prlsp-comment-buffer-name "*prlsp-comment*"
  "Name of the popup buffer used to draft PR comments.")

(defvar prlsp-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c p c") #'prlsp-comment-on-line)
    (define-key map (kbd "C-c p r") #'prlsp-reply-on-line)
    (define-key map (kbd "C-c p s") #'prlsp-show-thread)
    map)
  "Keymap for `prlsp-mode'.")

(define-minor-mode prlsp-mode
  "Minor mode with PRLSP-specific UX commands."
  :lighter " PRLSP"
  :keymap prlsp-mode-map)

(defvar-local prlsp-comment-origin-buffer nil)
(defvar-local prlsp-comment-origin-uri nil)
(defvar-local prlsp-comment-line nil)
(defvar-local prlsp-comment-kind 'create)
(defvar-local prlsp-comment-reply-comment-id nil)
(defvar-local prlsp-comment-body-start nil)

;;; --- Backend abstraction layer ---

(defun prlsp--detect-backend ()
  "Return the active LSP backend in current buffer: `eglot', `lsp', or nil."
  (cond
   ((bound-and-true-p eglot--managed-mode) 'eglot)
   ((bound-and-true-p lsp-mode) 'lsp)
   (t nil)))

(defun prlsp--active-p ()
  "Return non-nil when the current buffer is managed by prlsp."
  (pcase (prlsp--detect-backend)
    ('lsp
     (seq-some
      (lambda (ws)
        (eq (lsp--client-server-id (lsp--workspace-client ws)) 'prlsp))
      (or (and (boundp 'lsp--buffer-workspaces) lsp--buffer-workspaces)
          (and (fboundp 'lsp-workspaces) (lsp-workspaces)))))
    ('eglot
     (when-let ((server (eglot-current-server)))
       (cl-typep server 'prlsp-eglot-server)))
    (_ nil)))

(defun prlsp--buffer-uri ()
  "Return the LSP URI for the current buffer."
  (pcase (prlsp--detect-backend)
    ('lsp (lsp--buffer-uri))
    ('eglot (eglot--path-to-uri (buffer-file-name)))
    (_ (error "No LSP backend active"))))

(defun prlsp--execute-command (command arguments)
  "Execute workspace/executeCommand COMMAND with ARGUMENTS vector."
  (pcase (prlsp--detect-backend)
    ('lsp
     (lsp-request "workspace/executeCommand"
                  `(:command ,command :arguments ,arguments)))
    ('eglot
     (eglot-execute-command (eglot-current-server) command arguments))
    (_ (error "No LSP backend active"))))

(defun prlsp--code-actions (params)
  "Request textDocument/codeAction with PARAMS."
  (pcase (prlsp--detect-backend)
    ('lsp (lsp-request "textDocument/codeAction" params))
    ('eglot (jsonrpc-request (eglot-current-server)
                             :textDocument/codeAction params))
    (_ (error "No LSP backend active"))))

;;; --- Helpers ---

(defun prlsp--obj-get (obj key)
  "Read KEY from LSP response object OBJ (plist/hash/alist)."
  (let* ((kname (if (keywordp key)
                    (substring (symbol-name key) 1)
                  (symbol-name key)))
         (ksym (intern kname))
         (kkey (intern (concat ":" kname))))
    (cond
     ((hash-table-p obj)
      (or (gethash key obj)
          (gethash kkey obj)
          (gethash kname obj)
          (gethash ksym obj)))
     ((and (listp obj) (keywordp (car obj)))
      (or (plist-get obj key)
          (plist-get obj kkey)))
     ((listp obj)
      (or (cdr (assoc key obj))
          (cdr (assoc kkey obj))
          (cdr (assoc kname obj))
          (cdr (assoc ksym obj))))
     (t nil))))

(defun prlsp--arg-n (args n)
  "Get argument N from ARGS list/vector."
  (cond
   ((vectorp args) (and (< n (length args)) (aref args n)))
   ((listp args) (nth n args))
   (t nil)))

;;; --- Mode activation ---

(defun prlsp--maybe-enable-mode ()
  "Enable `prlsp-mode' only in buffers connected to prlsp."
  (if (prlsp--active-p)
      (prlsp-mode 1)
    (prlsp-mode -1)))

;;; --- Comment popup ---

(defun prlsp-comment--body ()
  "Return trimmed comment body from current popup buffer."
  (string-trim
   (buffer-substring-no-properties prlsp-comment-body-start (point-max))))

(defun prlsp-comment--open-popup (origin uri line kind &optional title comment-id thread-message)
  "Open popup buffer for comment KIND using ORIGIN/URI/LINE context.
THREAD-MESSAGE, when non-nil, is the full conversation text shown as context."
  (let ((popup (get-buffer-create prlsp-comment-buffer-name)))
    (pop-to-buffer popup)
    (let ((inhibit-read-only t)
          (source (file-name-nondirectory (buffer-name origin))))
      (erase-buffer)
      (if (fboundp 'markdown-mode)
          (markdown-mode)
        (text-mode))

      (setq-local prlsp-comment-origin-buffer origin)
      (setq-local prlsp-comment-origin-uri uri)
      (setq-local prlsp-comment-line line)
      (setq-local prlsp-comment-kind kind)
      (setq-local prlsp-comment-reply-comment-id comment-id)

      (insert (format "# %s\n\n"
                      (if (eq kind 'reply)
                          (or title "Reply to review thread")
                        (format "Comment for `%s` line %d" source line))))
      (when thread-message
        (insert "**Thread:**\n\n")
        (dolist (line (split-string thread-message "\n"))
          (insert (format "> %s\n" line)))
        (insert "\n"))
      (insert "Write your comment below.\n\n")
      (insert "---\n\n")
      (setq-local prlsp-comment-body-start (point))

      (use-local-map (copy-keymap (current-local-map)))
      (local-set-key (kbd "C-c C-c") #'prlsp-comment-submit)
      (local-set-key (kbd "C-c C-k") #'prlsp-comment-cancel)
      (setq header-line-format "PR comment: C-c C-c submit, C-c C-k cancel"))))

(defun prlsp--diagnostic-message-at-line (line)
  "Return the prlsp diagnostic message at LINE (1-indexed) in current buffer, or nil."
  (let ((line0 (1- line)))
    (pcase (prlsp--detect-backend)
      ('lsp
       (when-let ((diags (gethash (lsp--buffer-uri) (lsp-diagnostics t))))
         (seq-some
          (lambda (d)
            (let* ((range (gethash "range" d))
                   (start (gethash "start" range))
                   (src (gethash "source" d)))
              (when (and (= (gethash "line" start) line0)
                         (equal src "github-review"))
                (gethash "message" d))))
          diags)))
      ('eglot
       (seq-some
        (lambda (d)
          (when (= (1- (line-number-at-pos (flymake-diagnostic-beg d))) line0)
            (flymake-diagnostic-text d)))
        (flymake-diagnostics)))
      (_ nil))))

(defun prlsp--reply-targets (uri line)
  "Return available reply targets for URI at LINE as (TITLE . COMMENT-ID)."
  (let* ((line0 (max 0 (1- line)))
         (line-end (save-excursion (end-of-line) (current-column)))
         (params `(:textDocument (:uri ,uri)
                   :range (:start (:line ,line0 :character 0)
                                  :end (:line ,line0 :character ,line-end))
                   :context (:diagnostics ,(vector)
                             :triggerKind 1)))
         (actions (prlsp--code-actions params))
         (result nil))
    (dolist (action (append actions nil))
      (let* ((cmd (prlsp--obj-get action :command))
             (cmd-name (prlsp--obj-get cmd :command))
             (args (prlsp--obj-get cmd :arguments)))
        (when (and (stringp cmd-name) (string= cmd-name "prlsp.reply"))
          (let* ((comment-id (prlsp--arg-n args 0))
                 (title (or (prlsp--obj-get action :title)
                            (prlsp--obj-get cmd :title)
                            (format "Reply to comment %s" comment-id))))
            (when comment-id
              (push (cons title comment-id) result))))))
    (nreverse result)))

(defun prlsp-comment-cancel ()
  "Close the PR comment popup without posting."
  (interactive)
  (quit-window t))

(defun prlsp-comment-submit ()
  "Submit the current popup buffer as a PR review comment or reply."
  (interactive)
  (unless (and prlsp-comment-origin-buffer
               (buffer-live-p prlsp-comment-origin-buffer)
               prlsp-comment-line)
    (user-error "Missing PR comment context"))

  (let* ((origin prlsp-comment-origin-buffer)
         (uri prlsp-comment-origin-uri)
         (line prlsp-comment-line)
         (kind prlsp-comment-kind)
         (reply-id prlsp-comment-reply-comment-id)
         (body (prlsp-comment--body)))
    (when (string-empty-p body)
      (user-error "Comment body is empty"))

    (with-current-buffer origin
      (unless (prlsp--detect-backend)
        (user-error "No LSP backend is active in origin buffer"))
      (pcase kind
        ('reply
         (unless reply-id
           (user-error "Missing reply comment id"))
         (prlsp--execute-command
          "prlsp.reply"
          (vector reply-id
                  (or uri (prlsp--buffer-uri))
                  body)))
        (_
         (prlsp--execute-command
          "prlsp.createComment"
          (vector (or uri (prlsp--buffer-uri))
                  line
                  body)))))

    (quit-window t)
    (message
     (if (eq kind 'reply)
         "Submitted PR reply"
       (format "Submitted PR comment on line %d" line)))))

(defun prlsp-comment-on-line ()
  "Open a markdown popup to write a new PR comment for the current line."
  (interactive)
  (unless (and (prlsp--detect-backend) (buffer-file-name))
    (user-error "Current buffer must be a file with an LSP backend enabled"))

  (let* ((origin (current-buffer))
         (uri (prlsp--buffer-uri))
         (line (line-number-at-pos)))
    (prlsp-comment--open-popup origin uri line 'create)))

(defun prlsp-reply-on-line ()
  "Open a markdown popup to reply to an existing PR review thread."
  (interactive)
  (unless (and (prlsp--detect-backend) (buffer-file-name))
    (user-error "Current buffer must be a file with an LSP backend enabled"))

  (let* ((origin (current-buffer))
         (uri (prlsp--buffer-uri))
         (line (line-number-at-pos))
         (targets (condition-case err
                      (prlsp--reply-targets uri line)
                    (error
                     (user-error "Failed to load reply targets: %s" (error-message-string err))))))
    (unless targets
      (user-error "No unresolved review threads available to reply"))

    (let* ((choice (if (= (length targets) 1)
                       (caar targets)
                     (completing-read "Reply to thread: " (mapcar #'car targets) nil t)))
           (comment-id (cdr (assoc choice targets)))
           (thread-msg (prlsp--diagnostic-message-at-line line)))
      (prlsp-comment--open-popup origin uri line 'reply choice comment-id thread-msg))))

(defun prlsp-show-thread ()
  "Show the full review thread at the current line in a read-only popup."
  (interactive)
  (unless (and (prlsp--detect-backend) (buffer-file-name))
    (user-error "Current buffer must be a file with an LSP backend enabled"))

  (let* ((line (line-number-at-pos))
         (thread-msg (prlsp--diagnostic-message-at-line line)))
    (unless thread-msg
      (user-error "No review thread on this line"))

    (let ((buf (get-buffer-create "*prlsp-thread*")))
      (pop-to-buffer buf)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (if (fboundp 'markdown-mode)
            (markdown-mode)
          (text-mode))
        (insert (format "# Review thread (line %d)\n\n" line))
        (dolist (comment (split-string thread-msg "\n"))
          (insert comment)
          (insert "\n\n"))
        (setq buffer-read-only t)
        (goto-char (point-min))
        (use-local-map (copy-keymap (current-local-map)))
        (local-set-key (kbd "q") #'quit-window)
        (setq header-line-format "Review thread: q to close")))))

;;; --- Backend registration: lsp-mode ---

(with-eval-after-load 'lsp-mode
  (add-to-list 'lsp-language-id-configuration
               '(prog-mode . "plaintext"))

  (lsp-register-client
   (make-lsp-client
    :new-connection (lsp-stdio-connection
                     '("prlsp_go"))
    :major-modes '(prog-mode markdown-mode gfm-mode zig-mode)
    :server-id 'prlsp))

  (when (eq prlsp-preferred-backend 'lsp)
    (add-hook 'prog-mode-hook #'lsp-deferred)
    (add-hook 'gfm-mode-hook #'lsp-deferred))

  (add-hook 'lsp-managed-mode-hook #'prlsp--maybe-enable-mode))

;;; --- Backend registration: eglot ---

(with-eval-after-load 'eglot
  (defclass prlsp-eglot-server (eglot-lsp-server) ()
    :documentation "PRLSP eglot server.")

  (add-to-list 'eglot-server-programs
               '((prog-mode markdown-mode gfm-mode zig-mode)
                 . (prlsp-eglot-server "prlsp_go")))

  (when (eq prlsp-preferred-backend 'eglot)
    (add-hook 'prog-mode-hook #'eglot-ensure)
    (add-hook 'gfm-mode-hook #'eglot-ensure))

  (add-hook 'eglot-managed-mode-hook #'prlsp--maybe-enable-mode))

(add-hook 'after-change-major-mode-hook #'prlsp--maybe-enable-mode)

;;; --- Doom Emacs integration ---

(after! lsp-mode
  (map! :map prlsp-mode-map
        :localleader
        (:prefix ("p" . "prlsp")
         :desc "New PR comment" "c" #'prlsp-comment-on-line
         :desc "Reply to thread" "r" #'prlsp-reply-on-line
         :desc "Show thread" "s" #'prlsp-show-thread)))
