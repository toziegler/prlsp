;;; prlsp.el --- Emacs client helpers for PRLSP -*- lexical-binding: t; -*-

;; Author: PRLSP contributors
;; Keywords: tools, vc
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:
;;
;; This package provides Emacs UX helpers for the PRLSP language server:
;; - popup markdown buffer for creating review comments
;; - popup markdown buffer for replying to existing threads
;; - side markdown buffer for viewing a full thread at point
;; - optional auto-start hooks for lsp-mode or eglot
;; - `prlsp-mode' (minor mode) that auto-activates when PRLSP is active
;;
;; No keybindings are installed by default.  Users should bind commands from
;; their own configuration.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defgroup prlsp nil
  "Emacs integration for the PRLSP review-comment language server."
  :group 'tools
  :prefix "prlsp-")

(defcustom prlsp-command '("prlsp_go")
  "Command used to start the PRLSP server."
  :type '(repeat string)
  :group 'prlsp)

(defcustom prlsp-major-modes '(prog-mode)
  "Major modes for which PRLSP should be registered."
  :type '(repeat symbol)
  :group 'prlsp)

(defcustom prlsp-preferred-backend 'lsp
  "Preferred backend for auto-start hooks.
Valid values are `lsp' and `eglot'."
  :type '(choice (const :tag "lsp-mode" lsp)
                 (const :tag "eglot" eglot))
  :group 'prlsp)

(defcustom prlsp-auto-start t
  "When non-nil, add auto-start hooks for `prlsp-preferred-backend'."
  :type 'boolean
  :group 'prlsp)

(defcustom prlsp-comment-buffer-name "*prlsp-comment*"
  "Name of the popup buffer used to draft PR comments."
  :type 'string
  :group 'prlsp)

(defcustom prlsp-thread-buffer-name "*prlsp-thread*"
  "Name of the side buffer used to display a full review thread."
  :type 'string
  :group 'prlsp)

(defconst prlsp--diagnostic-source "github-review")

(defvar prlsp--lsp-registered nil)
(defvar prlsp--eglot-registered nil)
(defvar prlsp--hooks-installed nil)

(defvar prlsp-mode-map (make-sparse-keymap)
  "Keymap for `prlsp-mode'.

Intentionally empty by default; users should define their own bindings.")

;;;###autoload
(define-minor-mode prlsp-mode
  "Minor mode for PRLSP-specific buffer UX."
  :lighter " PRLSP"
  :keymap prlsp-mode-map)

(defvar-local prlsp-comment-origin-buffer nil)
(defvar-local prlsp-comment-origin-uri nil)
(defvar-local prlsp-comment-line nil)
(defvar-local prlsp-comment-kind 'create)
(defvar-local prlsp-comment-reply-comment-id nil)
(defvar-local prlsp-comment-body-start nil)

(defun prlsp--detect-backend ()
  "Return active backend in current buffer: `eglot', `lsp', or nil."
  (cond
   ((bound-and-true-p eglot--managed-mode) 'eglot)
   ((bound-and-true-p lsp-mode) 'lsp)
   (t nil)))

(defun prlsp--active-p ()
  "Return non-nil when current buffer is managed by PRLSP."
  (pcase (prlsp--detect-backend)
    ('lsp
     (seq-some
      (lambda (ws)
        (eq (lsp--client-server-id (lsp--workspace-client ws)) 'prlsp))
      (or (and (boundp 'lsp--buffer-workspaces) lsp--buffer-workspaces)
          (and (fboundp 'lsp-workspaces) (lsp-workspaces)))))
    ('eglot
     (when-let* ((server (eglot-current-server))
                 (proc (jsonrpc--process server))
                 (cmd (process-command proc))
                 (exe (car cmd))
                 (expected (car prlsp-command)))
       (string= (file-name-nondirectory exe)
                (file-name-nondirectory expected))))
    (_ nil)))

(defun prlsp--maybe-enable-mode ()
  "Enable `prlsp-mode' only in buffers connected to PRLSP."
  (if (prlsp--active-p)
      (prlsp-mode 1)
    (prlsp-mode -1)))

(defun prlsp--obj-get (obj key)
  "Read KEY from LSP response OBJ (plist/hash/alist)."
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
  "Return argument N from ARGS list/vector."
  (cond
   ((vectorp args) (and (< n (length args)) (aref args n)))
   ((listp args) (nth n args))
   (t nil)))

(defun prlsp--buffer-uri ()
  "Return current buffer URI for active backend."
  (pcase (prlsp--detect-backend)
    ('lsp (lsp--buffer-uri))
    ('eglot (eglot--path-to-uri (buffer-file-name)))
    (_ (error "No LSP backend active"))))

(defun prlsp--execute-command (command arguments)
  "Execute workspace command COMMAND with ARGUMENTS vector."
  (pcase (prlsp--detect-backend)
    ('lsp
     (lsp-request "workspace/executeCommand"
                  `(:command ,command :arguments ,arguments)))
    ('eglot
     (eglot-execute-command (eglot-current-server) command arguments))
    (_ (error "No LSP backend active"))))

(defun prlsp--code-actions (params)
  "Request textDocument/codeAction with PARAMS for active backend."
  (pcase (prlsp--detect-backend)
    ('lsp (lsp-request "textDocument/codeAction" params))
    ('eglot (jsonrpc-request (eglot-current-server)
                             :textDocument/codeAction params))
    (_ (error "No LSP backend active"))))

(defun prlsp--diag-covers-line-p (diag line0)
  "Return non-nil if DIAG range covers LINE0 (0-indexed)."
  (let* ((range (prlsp--obj-get diag :range))
         (start (prlsp--obj-get range :start))
         (end (prlsp--obj-get range :end))
         (start-line (prlsp--obj-get start :line))
         (end-line (or (prlsp--obj-get end :line) start-line)))
    (and (integerp start-line)
         (integerp end-line)
         (<= start-line line0)
         (<= line0 end-line))))

(defun prlsp--diagnostic-message-at-line (line)
  "Return PRLSP diagnostic message at LINE (1-indexed), or nil."
  (let ((line0 (1- line)))
    (pcase (prlsp--detect-backend)
      ('lsp
       (let ((diags
              (or (and (fboundp 'lsp--get-buffer-diagnostics)
                       (lsp--get-buffer-diagnostics))
                  (when-let ((all (and (fboundp 'lsp-diagnostics)
                                       (lsp-diagnostics t))))
                    (gethash (lsp--buffer-uri) all)))))
         (seq-some
          (lambda (d)
            (let ((src (prlsp--obj-get d :source)))
              (when (and (equal src prlsp--diagnostic-source)
                         (prlsp--diag-covers-line-p d line0))
                (prlsp--obj-get d :message))))
          (append diags nil))))
      ('eglot
       (seq-some
        (lambda (d)
          (when (= (1- (line-number-at-pos (flymake-diagnostic-beg d))) line0)
            (flymake-diagnostic-text d)))
        (flymake-diagnostics)))
      (_ nil))))

(defun prlsp--reply-targets (uri line)
  "Return reply targets for URI at LINE as (TITLE . COMMENT-ID)."
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

(defun prlsp-comment--body ()
  "Return trimmed comment body from current popup buffer."
  (string-trim
   (buffer-substring-no-properties prlsp-comment-body-start (point-max))))

(defun prlsp-comment--open-popup (origin uri line kind &optional title comment-id thread-message)
  "Open markdown popup for KIND with ORIGIN/URI/LINE context.
Optional TITLE, COMMENT-ID, and THREAD-MESSAGE are used for replies."
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
        (dolist (thread-line (split-string thread-message "\n"))
          (insert (format "> %s\n" thread-line)))
        (insert "\n"))
      (insert "Write your comment below.\n\n")
      (insert "---\n\n")
      (setq-local prlsp-comment-body-start (point))

      (use-local-map (copy-keymap (current-local-map)))
      (local-set-key (kbd "C-c C-c") #'prlsp-comment-submit)
      (local-set-key (kbd "C-c C-k") #'prlsp-comment-cancel)
      (setq header-line-format "PR comment: C-c C-c submit, C-c C-k cancel"))))

;;;###autoload
(defun prlsp-comment-cancel ()
  "Close the PR comment popup without posting."
  (interactive)
  (quit-window t))

;;;###autoload
(defun prlsp-comment-submit ()
  "Submit popup buffer as PR review comment or reply."
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

;;;###autoload
(defun prlsp-comment-on-line ()
  "Open markdown popup to write a new PR comment on current line."
  (interactive)
  (unless (and (prlsp--detect-backend) (buffer-file-name))
    (user-error "Current buffer must be a file with an LSP backend enabled"))

  (let ((origin (current-buffer))
        (uri (prlsp--buffer-uri))
        (line (line-number-at-pos)))
    (prlsp-comment--open-popup origin uri line 'create)))

;;;###autoload
(defun prlsp-reply-on-line ()
  "Open markdown popup to reply to a PR review thread on current line."
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

;;;###autoload
(defun prlsp-show-thread ()
  "Show full review thread at current line in markdown side buffer."
  (interactive)
  (unless (and (prlsp--detect-backend) (buffer-file-name))
    (user-error "Current buffer must be a file with an LSP backend enabled"))

  (let* ((line (line-number-at-pos))
         (thread-msg (prlsp--diagnostic-message-at-line line)))
    (unless thread-msg
      (user-error "No review thread on this line"))

    (let ((buf (get-buffer-create prlsp-thread-buffer-name)))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (erase-buffer)
          (if (fboundp 'markdown-mode)
              (markdown-mode)
            (text-mode))
          (insert (format "# Review thread (line %d)\n\n" line))
          (dolist (comment (split-string thread-msg "\n" t))
            (insert (format "- %s\n\n" comment)))
          (setq buffer-read-only t)
          (goto-char (point-min))
          (use-local-map (copy-keymap (current-local-map)))
          (local-set-key (kbd "q") #'quit-window)
          (setq header-line-format "Review thread: q to close")))

      (display-buffer-in-side-window
       buf
       '((side . right)
         (slot . 1)
         (window-width . 0.4))))))

(defun prlsp--register-lsp ()
  "Register PRLSP with lsp-mode after lsp-mode loads."
  (with-eval-after-load 'lsp-mode
    (unless prlsp--lsp-registered
      (add-to-list 'lsp-language-id-configuration '(prog-mode . "plaintext"))
      (lsp-register-client
       (make-lsp-client
        :new-connection (lsp-stdio-connection prlsp-command)
        :major-modes prlsp-major-modes
        :server-id 'prlsp))
      (add-hook 'lsp-managed-mode-hook #'prlsp--maybe-enable-mode)
      (setq prlsp--lsp-registered t))))

(defun prlsp--register-eglot ()
  "Register PRLSP with eglot after eglot loads."
  (with-eval-after-load 'eglot
    (unless prlsp--eglot-registered
      (add-to-list 'eglot-server-programs
                   `(,prlsp-major-modes
                     . ,prlsp-command))
      (add-hook 'eglot-managed-mode-hook #'prlsp--maybe-enable-mode)
      (setq prlsp--eglot-registered t))))

(defun prlsp--install-autostart-hooks ()
  "Install backend-specific auto-start hooks."
  (pcase prlsp-preferred-backend
    ('lsp
     (add-hook 'prog-mode-hook #'lsp-deferred))
    ('eglot
     (add-hook 'prog-mode-hook #'eglot-ensure))))

(defun prlsp--remove-autostart-hooks ()
  "Remove backend-specific auto-start hooks."
  (remove-hook 'prog-mode-hook #'lsp-deferred)
  (remove-hook 'prog-mode-hook #'eglot-ensure))

;;;###autoload
(defun prlsp-setup ()
  "Register PRLSP integration and optional auto-start hooks."
  (interactive)
  (prlsp--register-lsp)
  (prlsp--register-eglot)

  (unless prlsp--hooks-installed
    (add-hook 'after-change-major-mode-hook #'prlsp--maybe-enable-mode)
    (setq prlsp--hooks-installed t))

  (when prlsp-auto-start
    (prlsp--install-autostart-hooks)))

;;;###autoload
(defun prlsp-teardown ()
  "Remove PRLSP hooks added by `prlsp-setup'."
  (interactive)
  (prlsp--remove-autostart-hooks)
  (remove-hook 'after-change-major-mode-hook #'prlsp--maybe-enable-mode)
  (remove-hook 'lsp-managed-mode-hook #'prlsp--maybe-enable-mode)
  (remove-hook 'eglot-managed-mode-hook #'prlsp--maybe-enable-mode)
  (setq prlsp--hooks-installed nil))

(provide 'prlsp)

;;; prlsp.el ends here
