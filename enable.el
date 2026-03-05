
;; Emacs integration for the prlsp server.

(require 'subr-x)

(defvar prlsp-comment-buffer-name "*prlsp-comment*"
  "Name of the popup buffer used to draft PR comments.")

(defvar-local prlsp-comment-origin-buffer nil)
(defvar-local prlsp-comment-origin-uri nil)
(defvar-local prlsp-comment-line nil)
(defvar-local prlsp-comment-kind 'create)
(defvar-local prlsp-comment-reply-comment-id nil)
(defvar-local prlsp-comment-body-start nil)

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

(defun prlsp-comment--body ()
  "Return trimmed comment body from current popup buffer."
  (string-trim
   (buffer-substring-no-properties prlsp-comment-body-start (point-max))))

(defun prlsp-comment--open-popup (origin uri line kind &optional title comment-id)
  "Open popup buffer for comment KIND using ORIGIN/URI/LINE context."
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
      (insert "Write your comment below.\n\n")
      (insert "---\n\n")
      (setq-local prlsp-comment-body-start (point))

      (use-local-map (copy-keymap (current-local-map)))
      (local-set-key (kbd "C-c C-c") #'prlsp-comment-submit)
      (local-set-key (kbd "C-c C-k") #'prlsp-comment-cancel)
      (setq header-line-format "PR comment: C-c C-c submit, C-c C-k cancel"))))

(defun prlsp--reply-targets (uri line)
  "Return available reply targets for URI at LINE as (TITLE . COMMENT-ID)."
  (let* ((line0 (max 0 (1- line)))
         (line-end (save-excursion (end-of-line) (current-column)))
         (params `(:textDocument (:uri ,uri)
                   :range (:start (:line ,line0 :character 0)
                                  :end (:line ,line0 :character ,line-end))
                   :context (:diagnostics ,(vector)
                             :triggerKind 1)))
         (actions (lsp-request "textDocument/codeAction" params))
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
      (unless (bound-and-true-p lsp-mode)
        (user-error "lsp-mode is not active in origin buffer"))
      (pcase kind
        ('reply
         (unless reply-id
           (user-error "Missing reply comment id"))
         (lsp-request
          "workspace/executeCommand"
          `(:command "prlsp.reply"
                     :arguments [,reply-id
                                 ,(or uri (lsp--buffer-uri))
                                 ,body])))
        (_
         (lsp-request
          "workspace/executeCommand"
          `(:command "prlsp.createComment"
                     :arguments [,(or uri (lsp--buffer-uri))
                                 ,line
                                 ,body])))))

    (quit-window t)
    (message
     (if (eq kind 'reply)
         "Submitted PR reply"
       (format "Submitted PR comment on line %d" line)))))

(defun prlsp-comment-on-line ()
  "Open a markdown popup to write a new PR comment for the current line."
  (interactive)
  (unless (and (bound-and-true-p lsp-mode) (buffer-file-name))
    (user-error "Current buffer must be a file with lsp-mode enabled"))

  (let* ((origin (current-buffer))
         (uri (lsp--buffer-uri))
         (line (line-number-at-pos)))
    (prlsp-comment--open-popup origin uri line 'create)))

(defun prlsp-reply-on-line ()
  "Open a markdown popup to reply to an existing PR review thread."
  (interactive)
  (unless (and (bound-and-true-p lsp-mode) (buffer-file-name))
    (user-error "Current buffer must be a file with lsp-mode enabled"))

  (let* ((origin (current-buffer))
         (uri (lsp--buffer-uri))
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
           (comment-id (cdr (assoc choice targets))))
      (prlsp-comment--open-popup origin uri line 'reply choice comment-id))))

(with-eval-after-load 'lsp-mode
  (add-to-list 'lsp-language-id-configuration
               '(prog-mode . "plaintext"))

  (lsp-register-client
   (make-lsp-client
    :new-connection (lsp-stdio-connection
                     '("python3" "-m" "prlsp"))
    :major-modes '(prog-mode markdown-mode gfm-mode)
    :server-id 'prlsp))

  (add-hook 'prog-mode-hook #'lsp-deferred)
  (add-hook 'gfm-mode-hook #'lsp-deferred)
  (define-key prog-mode-map (kbd "C-c p c") #'prlsp-comment-on-line)
  (define-key prog-mode-map (kbd "C-c p r") #'prlsp-reply-on-line))


