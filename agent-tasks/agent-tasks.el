;;; agent-tasks.el --- Spawn and manage pilish agent tasks -*- lexical-binding: t; -*-

;; Author: Tim Gallant <me@timgallant.us>
;; Package-Requires: ((emacs "30.1"))

;;; Commentary:

;; Spawn pilish sessions into their own git worktree and persp-mode layout,
;; from Emacs or from a running pi session (via the spawn_task extension),
;; and manage them from a dashboard.  See docs/plans/ for the design.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'format-spec)

(defgroup agent-tasks nil
  "Spawn and manage pilish agent tasks."
  :group 'tools)

(defcustom agent-tasks-max-depth 3
  "Maximum nesting of tasks spawned by other tasks.
A task spawned from Emacs or an untracked session has depth 1."
  :type 'natnum)

(defcustom agent-tasks-max-live 8
  "Maximum number of tasks with a live session."
  :type 'natnum)

(defcustom agent-tasks-prompt-preamble
  "You are working in the git worktree %w on branch %b (from %s), created for this task. Work and commit there; do not create other branches or worktrees."
  "Text sent before a task's prompt, or nil for none.
%w is replaced by the worktree, %b by the branch and %s by the base."
  :type '(choice string (const nil)))

;;;; pilish adapter
;;
;; The only code that touches pilish.  Several of these use pilish internals
;; (double-dash names), so keep them small and in one place.

(defvar pilish--status)
(defvar pilish--state)
(defvar pilish--process)
(defvar pilish--input-buffer)
(defvar pilish-quit-without-confirmation)
(defvar persp-kill-foreign-buffer-behaviour)
(declare-function pilish--setup-session "pilish" (dir &optional session))
(declare-function pilish-send "pilish-input" ())
(declare-function pilish "pilish" (&optional session))
(declare-function pilish-open-session-file "pilish" (session-file))

(defun agent-tasks--pilish-start (dir)
  "Start a pilish session in DIR without displaying it; return the chat buffer."
  (require 'pilish)
  (pilish--setup-session dir))

(defun agent-tasks--pilish-input (chat)
  "Return the input buffer of CHAT."
  (buffer-local-value 'pilish--input-buffer chat))

(defun agent-tasks--pilish-send (chat text)
  "Send TEXT as a prompt to the session of CHAT."
  (with-current-buffer (agent-tasks--pilish-input chat)
    (erase-buffer)
    (insert text)
    (pilish-send)))

(defun agent-tasks--pilish-chat-buffers ()
  "Return all live pilish chat buffers."
  (seq-filter (lambda (b)
                (eq (buffer-local-value 'major-mode b) 'pilish-chat-mode))
              (buffer-list)))

(defun agent-tasks--pilish-session-file (chat)
  "Return the session file of CHAT, or nil."
  (plist-get (buffer-local-value 'pilish--state chat) :session-file))

(defun agent-tasks--pilish-status (chat)
  "Return the pilish status of CHAT: idle, sending, streaming or compacting."
  (buffer-local-value 'pilish--status chat))

(defun agent-tasks--pilish-process-live-p (chat)
  "Return non-nil when the pi process of CHAT is running."
  (let ((proc (buffer-local-value 'pilish--process chat)))
    (and (processp proc) (process-live-p proc))))

(defun agent-tasks--pilish-show (chat)
  "Display the session of CHAT in the selected frame."
  (with-current-buffer chat (pilish)))

(defun agent-tasks--pilish-resume (session-file)
  "Resume SESSION-FILE as a live session in the selected window.
Return the chat buffer."
  (require 'pilish)
  (pilish-open-session-file session-file))

(defun agent-tasks--pilish-kill (chat)
  "Kill the session of CHAT and its buffers without asking."
  (let ((pilish-quit-without-confirmation t)
        (persp-kill-foreign-buffer-behaviour 'kill))
    (kill-buffer chat)))

;;;; Layout adapter (persp-mode)

(defvar persp-nil-name)
(declare-function persp-add-new "persp-mode")
(declare-function persp-add-buffer "persp-mode")
(declare-function persp-kill "persp-mode")
(declare-function persp-switch "persp-mode")
(declare-function persp-get-by-name "persp-mode")
(declare-function persp-with-name-exists-p "persp-mode")
(declare-function persp--buffer-in-persps "persp-mode" (buf))
(declare-function get-current-persp "persp-mode")
(declare-function safe-persp-name "persp-mode" (p))

(defun agent-tasks--layout-exists-p (name)
  "Return non-nil when layout NAME exists."
  (persp-with-name-exists-p name))

(defun agent-tasks--layout-create (name buffers)
  "Create layout NAME containing BUFFERS without switching to it."
  (persp-add-buffer buffers (persp-add-new name) nil nil))

(defun agent-tasks--layout-of-buffer (buffer)
  "Return the name of a layout containing BUFFER, or the default layout's."
  (if-let* ((persps (persp--buffer-in-persps buffer)))
      (safe-persp-name (car persps))
    persp-nil-name))

(defun agent-tasks--current-layout ()
  "Return the name of the current layout."
  (safe-persp-name (get-current-persp)))

(defun agent-tasks--layout-switch (name)
  "Switch the selected frame to layout NAME, creating it if needed."
  (persp-switch name))

(defun agent-tasks--layout-kill (name)
  "Kill layout NAME, keeping its buffers."
  (when (agent-tasks--layout-exists-p name)
    (persp-kill name t)))

;;;; Git layer

(defun agent-tasks--git (dir &rest args)
  "Run git ARGS in DIR.  Return (EXIT-CODE . TRIMMED-OUTPUT)."
  (let ((default-directory (file-name-as-directory dir)))
    (with-temp-buffer
      (let ((code (apply #'process-file "git" nil t nil args)))
        (cons code (string-trim (buffer-string)))))))

(defun agent-tasks--git-ok (dir &rest args)
  "Run git ARGS in DIR and return its output, signalling on failure."
  (pcase-let ((`(,code . ,out) (apply #'agent-tasks--git dir args)))
    (unless (zerop code)
      (error "git %s failed: %s" (string-join args " ") out))
    out))

(defun agent-tasks--git-p (dir &rest args)
  "Return non-nil when git ARGS succeed in DIR."
  (zerop (car (apply #'agent-tasks--git dir args))))

(defun agent-tasks--main-checkout (dir)
  "Return the main checkout of the repository containing DIR.
For a linked worktree this is the repository it was created from."
  (let ((dir (expand-file-name dir)))
    (pcase-let ((`(,code . ,out)
                 (if (file-directory-p dir)
                     (agent-tasks--git dir "rev-parse" "--path-format=absolute"
                                       "--git-common-dir")
                   '(1 . ""))))
      (unless (zerop code)
        (error "%s is not inside a git repository" (abbreviate-file-name dir)))
      (file-name-as-directory
       (file-truename (file-name-directory (directory-file-name out)))))))

(defun agent-tasks--local-branches (repo)
  "Return the local branch names of REPO."
  (split-string (agent-tasks--git-ok repo "for-each-ref"
                                     "--format=%(refname:short)" "refs/heads")
                "\n" t))

(defun agent-tasks--commit-p (repo ref)
  "Return non-nil when REF names a commit in REPO."
  (agent-tasks--git-p repo "rev-parse" "--verify" "--quiet"
                      (concat ref "^{commit}")))

(defun agent-tasks--branch-p (repo branch)
  "Return non-nil when local BRANCH exists in REPO."
  (agent-tasks--git-p repo "show-ref" "--verify" "--quiet"
                      (concat "refs/heads/" branch)))

(defun agent-tasks--origin-head (repo)
  "Return the base named by REPO's origin/HEAD, or nil.
Prefers the local branch of the same name when it exists."
  (pcase-let ((`(,code . ,out)
               (agent-tasks--git repo "symbolic-ref" "--quiet" "--short"
                                 "refs/remotes/origin/HEAD")))
    (when (zerop code)
      (let ((local (string-remove-prefix "origin/" out)))
        (cond ((agent-tasks--branch-p repo local) local)
              ((agent-tasks--commit-p repo out) out))))))

(defun agent-tasks--resolve-base (repo base)
  "Return (BRANCH . FELL-BACK) to branch new work from in REPO.
Use BASE when non-nil, else main, else origin/HEAD, else master.
FELL-BACK is non-nil when something other than main was chosen
without BASE being given."
  (let ((branches (string-join (agent-tasks--local-branches repo) ", ")))
    (when (string-empty-p branches)
      (setq branches "(none)"))
    (cond
     (base
      (unless (agent-tasks--commit-p repo base)
        (error "Base branch %s not found in %s; branches: %s"
               base (abbreviate-file-name repo) branches))
      (cons base nil))
     ((agent-tasks--commit-p repo "refs/heads/main") (cons "main" nil))
     ((agent-tasks--origin-head repo) (cons (agent-tasks--origin-head repo) t))
     ((agent-tasks--commit-p repo "refs/heads/master") (cons "master" t))
     (t (error "No main, origin/HEAD or master in %s; branches: %s"
               (abbreviate-file-name repo) branches)))))

(defun agent-tasks--main-checkout-dir-p (dir)
  "Return non-nil when DIR is an absolute path to a main git checkout.
Linked worktrees (whose .git is a file) do not count."
  (and (or (file-name-absolute-p dir) (string-prefix-p "~" dir))
       (file-directory-p (expand-file-name ".git" dir))))

(defun agent-tasks--project-name (dir)
  "Return the basename of project DIR."
  (file-name-nondirectory (directory-file-name dir)))

(defun agent-tasks--known-projects ()
  "Return projectile's known projects, or nil."
  (bound-and-true-p projectile-known-projects))

(defun agent-tasks--resolve-repo (repo cwd projects)
  "Return the main checkout for REPO.
REPO is nil (use CWD's repository), an absolute or ~ path, or a
project name matched by directory basename against PROJECTS.
Linked worktrees in PROJECTS are ignored."
  (cond
   ((or (null repo) (string-empty-p repo))
    (agent-tasks--main-checkout cwd))
   ((or (file-name-absolute-p repo) (string-prefix-p "~" repo))
    (agent-tasks--main-checkout repo))
   (t
    (let* ((candidates
            (delete-dups
             (cl-loop for p in projects
                      when (agent-tasks--main-checkout-dir-p p)
                      collect (file-name-as-directory
                               (file-truename (expand-file-name p))))))
           (matches (cl-remove-if-not
                     (lambda (p) (equal (agent-tasks--project-name p) repo))
                     candidates)))
      (pcase matches
        (`(,one) one)
        ('nil (error "Unknown repo %s; pass a path or one of: %s" repo
                     (string-join
                      (delete-dups (mapcar #'agent-tasks--project-name candidates))
                      ", ")))
        (_ (error "Ambiguous repo %s; candidates: %s" repo
                  (string-join (mapcar #'abbreviate-file-name matches) ", "))))))))

(defun agent-tasks--worktree-dir (repo name)
  "Return the worktree directory for task NAME in REPO."
  (file-name-as-directory (concat (directory-file-name repo) "-" name)))

(defconst agent-tasks--name-regexp "\\`[A-Za-z0-9][A-Za-z0-9_-]*\\'"
  "Valid task names: they become a layout, a branch and a directory suffix.")

(defun agent-tasks--validate-name (repo name)
  "Signal an error unless NAME is usable for a new task in REPO."
  (unless (string-match-p agent-tasks--name-regexp name)
    (error "Invalid task name %S; use letters, digits, - and _" name))
  (when (agent-tasks--branch-p repo name)
    (error "Branch %s already exists in %s" name (abbreviate-file-name repo)))
  (let ((dir (agent-tasks--worktree-dir repo name)))
    (when (file-exists-p dir)
      (error "Directory %s already exists" (abbreviate-file-name dir))))
  nil)

(defun agent-tasks--create-worktree (repo name base)
  "Create a worktree for NAME in REPO on a new branch from BASE.
Return its directory."
  (let ((dir (agent-tasks--worktree-dir repo name)))
    (agent-tasks--git-ok repo "worktree" "add" "-q" "-b" name
                         (directory-file-name dir) base)
    dir))

;;;; Registry and persistence

(defcustom agent-tasks-file
  (locate-user-emacs-file ".cache/agent-tasks.eld")
  "File where task metadata is persisted between Emacs sessions."
  :type 'file)

(cl-defstruct (agent-tasks-task (:constructor agent-tasks-task-create)
                                (:copier nil))
  "A spawned agent task."
  name repo worktree branch base parent depth created prompt session-file
  last-status
  ;; Runtime only, not persisted:
  chat-buffer done shown busy-seen)

(defconst agent-tasks--persisted-slots
  '(name repo worktree branch base parent depth created prompt session-file
    last-status)
  "Task slots written to `agent-tasks-file'.")

(defun agent-tasks--task-to-plist (task)
  "Return the persisted slots of TASK as a plist."
  (cl-loop for slot in agent-tasks--persisted-slots
           append (list (intern (format ":%s" slot))
                        (cl-struct-slot-value 'agent-tasks-task slot task))))

(defun agent-tasks--task-from-plist (plist)
  "Return a task built from PLIST."
  (let ((task (agent-tasks-task-create)))
    (dolist (slot agent-tasks--persisted-slots task)
      (setf (cl-struct-slot-value 'agent-tasks-task slot task)
            (plist-get plist (intern (format ":%s" slot)))))))

(defun agent-tasks--save (tasks)
  "Write TASKS to `agent-tasks-file', atomically."
  (let* ((file (expand-file-name agent-tasks-file))
         (dir (file-name-directory file))
         (tmp (progn (make-directory dir t)
                     (make-temp-file (expand-file-name "agent-tasks" dir)
                                     nil ".tmp"))))
    (with-temp-file tmp
      (let ((print-length nil) (print-level nil))
        (insert ";; agent-tasks state -*- lisp-data -*-\n")
        (prin1 (mapcar #'agent-tasks--task-to-plist tasks) (current-buffer))
        (insert "\n")))
    (rename-file tmp file t)))

(defvar agent-tasks--tasks (make-hash-table :test #'equal)
  "Registry of tasks, keyed by name.")

(defun agent-tasks--task-list ()
  "Return all registered tasks, oldest first."
  (sort (hash-table-values agent-tasks--tasks)
        (lambda (a b) (string< (or (agent-tasks-task-created a) "")
                               (or (agent-tasks-task-created b) "")))))

(defun agent-tasks--persist ()
  "Save the registry to `agent-tasks-file'."
  (agent-tasks--save (agent-tasks--task-list)))

(defun agent-tasks--load ()
  "Return the tasks stored in `agent-tasks-file', or nil."
  (when (file-readable-p agent-tasks-file)
    (condition-case err
        (mapcar #'agent-tasks--task-from-plist
                (with-temp-buffer
                  (insert-file-contents agent-tasks-file)
                  (read (current-buffer))))
      (error
       (message "agent-tasks: could not read %s: %s"
                agent-tasks-file (error-message-string err))
       nil))))

;;;; Spawn

(defun agent-tasks--live-p (task)
  "Return non-nil when TASK has a live chat buffer."
  (buffer-live-p (agent-tasks-task-chat-buffer task)))

(defun agent-tasks--task-for-chat (chat)
  "Return the registered task whose chat buffer is CHAT, or nil."
  (seq-find (lambda (task) (eq (agent-tasks-task-chat-buffer task) chat))
            (hash-table-values agent-tasks--tasks)))

(defun agent-tasks--resolve-parent (session-file)
  "Return (PARENT-NAME . PARENT-DEPTH) for the session SESSION-FILE."
  (if-let* ((chat (and session-file
                       (seq-find (lambda (b)
                                   (equal (agent-tasks--pilish-session-file b)
                                          session-file))
                                 (agent-tasks--pilish-chat-buffers)))))
      (if-let* ((task (agent-tasks--task-for-chat chat)))
          (cons (agent-tasks-task-name task) (agent-tasks-task-depth task))
        (cons (agent-tasks--layout-of-buffer chat) 0))
    (cons nil 0)))

(defun agent-tasks--full-prompt (prompt worktree branch base)
  "Return PROMPT preceded by `agent-tasks-prompt-preamble'.
WORKTREE, BRANCH and BASE fill in the preamble's format specs."
  (if agent-tasks-prompt-preamble
      (concat (format-spec agent-tasks-prompt-preamble
                           `((?w . ,worktree) (?b . ,branch) (?s . ,base)))
              "\n\n" prompt)
    prompt))

(defun agent-tasks--timestamp ()
  "Return the current local time as an ISO 8601 string."
  (format-time-string "%FT%T"))

(cl-defun agent-tasks-spawn (&key name prompt repo base cwd parent-session)
  "Spawn task NAME: worktree, layout and pilish session running PROMPT.
REPO and BASE select the repository and base branch (see
`agent-tasks--resolve-repo' and `agent-tasks--resolve-base'); CWD is
the directory the request came from; PARENT-SESSION is the session
file of the requesting pi session.  Return a plist describing the task."
  (when (string-blank-p (or prompt ""))
    (error "Refusing to spawn %s with an empty prompt" name))
  (let* ((repo (agent-tasks--resolve-repo repo (or cwd default-directory)
                                          (agent-tasks--known-projects)))
         (base (agent-tasks--resolve-base repo base))
         (parent (agent-tasks--resolve-parent parent-session))
         (depth (1+ (cdr parent)))
         (live (seq-count #'agent-tasks--live-p
                          (hash-table-values agent-tasks--tasks))))
    (agent-tasks--validate-name repo name)
    (when (or (gethash name agent-tasks--tasks)
              (agent-tasks--layout-exists-p name))
      (error "Layout %s already exists" name))
    (when (> depth agent-tasks-max-depth)
      (error "Refusing to spawn %s: depth limit %d reached (parent %s)"
             name agent-tasks-max-depth (car parent)))
    (when (>= live agent-tasks-max-live)
      (error "Refusing to spawn %s: %d live tasks (agent-tasks-max-live)"
             name live))
    (let ((worktree (agent-tasks--create-worktree repo name (car base))))
      (condition-case err
          (let* ((chat (agent-tasks--pilish-start worktree))
                 (task (agent-tasks-task-create
                        :name name :repo repo :worktree worktree :branch name
                        :base (car base) :parent (car parent) :depth depth
                        :created (agent-tasks--timestamp) :prompt prompt
                        :last-status 'working :chat-buffer chat)))
            (agent-tasks--layout-create
             name (list chat (agent-tasks--pilish-input chat)))
            (puthash name task agent-tasks--tasks)
            (agent-tasks--pilish-send
             chat (agent-tasks--full-prompt prompt worktree name (car base)))
            (agent-tasks--persist)
            (list :task name :layout name :worktree worktree :branch name
                  :base (car base) :baseFellBack (if (cdr base) t :false)))
        (error
         (error "Worktree %s was created, then spawning failed: %s"
                (abbreviate-file-name worktree) (error-message-string err)))))))

(defun agent-tasks-spawn-from-file (file)
  "Spawn a task from the JSON request in FILE and return a JSON reply.
FILE holds name, prompt, repo, base, cwd and parentSession; it is
deleted.  Errors are returned as {\"error\": MESSAGE}."
  (json-serialize
   (condition-case err
       (let ((req (with-temp-buffer
                    (insert-file-contents file)
                    (json-parse-buffer :object-type 'plist :null-object nil
                                       :false-object nil))))
         (delete-file file)
         (agent-tasks-spawn :name (plist-get req :name)
                            :prompt (plist-get req :prompt)
                            :repo (plist-get req :repo)
                            :base (plist-get req :base)
                            :cwd (plist-get req :cwd)
                            :parent-session (plist-get req :parentSession)))
     (error (list :error (error-message-string err))))))

;;;; Status

(defcustom agent-tasks-notify-function #'agent-tasks--notify-message
  "Function called with a task when it finishes working."
  :type 'function)

(defun agent-tasks--notify-message (task)
  "Report in the echo area that TASK finished."
  (message "agent-tasks: %s finished" (agent-tasks-task-name task)))

(defun agent-tasks--session-status (chat)
  "Return working, idle or exited for the live session of CHAT."
  (cond ((not (agent-tasks--pilish-process-live-p chat)) 'exited)
        ((memq (agent-tasks--pilish-status chat) '(sending streaming compacting))
         'working)
        (t 'idle)))

(defun agent-tasks--status (task)
  "Return the display status of TASK.
One of working, idle, done, exited, dormant, interrupted or missing."
  (if (agent-tasks--live-p task)
      (let ((status (agent-tasks--session-status
                     (agent-tasks-task-chat-buffer task))))
        (if (and (eq status 'idle) (agent-tasks-task-done task)) 'done status))
    (cond ((not (file-directory-p (agent-tasks-task-worktree task))) 'missing)
          ((eq (agent-tasks-task-last-status task) 'working) 'interrupted)
          (t 'dormant))))

(defvar agent-tasks--mode-line ""
  "Mode-line summary of task activity, updated by `agent-tasks--poll'.")
(put 'agent-tasks--mode-line 'risky-local-variable t)

(defun agent-tasks--mode-line-string ()
  "Return \" ⚙WORKING ●DONE\", omitting zero counts."
  (let ((statuses (mapcar #'agent-tasks--status (agent-tasks--task-list))))
    (concat (let ((n (seq-count (lambda (s) (eq s 'working)) statuses)))
              (if (> n 0) (format " ⚙%d" n) ""))
            (let ((n (seq-count (lambda (s) (eq s 'done)) statuses)))
              (if (> n 0) (format " ●%d" n) "")))))

(defvar agent-tasks-after-poll-hook nil
  "Hook run after a poll that changed some task.")

(defun agent-tasks--poll ()
  "Update task statuses, mark finished tasks done and persist changes."
  (let ((changed nil)
        (current (agent-tasks--current-layout)))
    (dolist (task (agent-tasks--task-list))
      (when (agent-tasks--live-p task)
        (let* ((chat (agent-tasks-task-chat-buffer task))
               (status (agent-tasks--session-status chat))
               (file (agent-tasks--pilish-session-file chat)))
          (when (and (eq status 'idle)
                     (or (eq (agent-tasks-task-last-status task) 'working)
                         (agent-tasks-task-busy-seen task))
                     (not (equal current (agent-tasks-task-name task))))
            (setf (agent-tasks-task-done task) t)
            (funcall agent-tasks-notify-function task))
          (unless (eq status 'working)
            (setf (agent-tasks-task-busy-seen task) nil))
          (unless (eq status (agent-tasks-task-last-status task))
            (setf (agent-tasks-task-last-status task) status
                  changed t))
          (when (and file (not (equal file (agent-tasks-task-session-file task))))
            (setf (agent-tasks-task-session-file task) file
                  changed t)))))
    (let ((line (agent-tasks--mode-line-string)))
      (unless (equal line agent-tasks--mode-line)
        (setq agent-tasks--mode-line line)
        (force-mode-line-update t)))
    (when changed
      (agent-tasks--persist)
      (run-hooks 'agent-tasks-after-poll-hook))
    changed))

(defcustom agent-tasks-poll-interval 2
  "Seconds between status polls."
  :type 'number)

(defvar agent-tasks--timer nil
  "Timer running `agent-tasks--poll'.")

(defvar persp-activated-functions)

(defun agent-tasks--status-watcher (_symbol newval _operation where)
  "Latch activity of task sessions as `pilish--status' changes.
Turns shorter than the poll interval would otherwise go unnoticed.
WHERE is the buffer whose binding changed to NEWVAL.  This runs inside
pilish's own `setq', so it must never signal."
  (condition-case err
      (when-let* (((bufferp where))
                  (task (agent-tasks--task-for-chat where)))
        (if (eq newval 'idle)
            (run-at-time 0 nil #'agent-tasks--poll-safely)
          (setf (agent-tasks-task-busy-seen task) t)))
    (error (message "agent-tasks: status watcher failed: %s"
                    (error-message-string err)))))

(defun agent-tasks--poll-safely ()
  "Run `agent-tasks--poll', reporting rather than signalling errors."
  (condition-case err (agent-tasks--poll)
    (error (message "agent-tasks: poll failed: %s" (error-message-string err)))))

(defun agent-tasks--load-into-registry ()
  "Add persisted tasks that are not already registered."
  (dolist (task (agent-tasks--load))
    (unless (gethash (agent-tasks-task-name task) agent-tasks--tasks)
      (puthash (agent-tasks-task-name task) task agent-tasks--tasks))))

(defcustom agent-tasks-start-server t
  "Whether `agent-tasks-mode' starts the Emacs server.
The pi spawn_task tool reaches Emacs through emacsclient."
  :type 'boolean)

(declare-function server-running-p "server" (&optional name))

;;;###autoload
(define-minor-mode agent-tasks-mode
  "Track agent tasks: poll their status and restore persisted tasks."
  :global t
  (when agent-tasks--timer
    (cancel-timer agent-tasks--timer)
    (setq agent-tasks--timer nil))
  (remove-hook 'persp-activated-functions #'agent-tasks--on-layout-activated)
  (remove-variable-watcher 'pilish--status #'agent-tasks--status-watcher)
  (setq global-mode-string (delq 'agent-tasks--mode-line global-mode-string))
  (when agent-tasks-mode
    (when agent-tasks-start-server
      (require 'server)
      (unless (server-running-p)
        (server-start)))
    (agent-tasks--load-into-registry)
    (add-variable-watcher 'pilish--status #'agent-tasks--status-watcher)
    (add-hook 'persp-activated-functions #'agent-tasks--on-layout-activated t)
    (unless (listp global-mode-string)
      (setq global-mode-string (list global-mode-string)))
    (setq global-mode-string (append global-mode-string '(agent-tasks--mode-line)))
    (setq agent-tasks--timer
          (run-at-time agent-tasks-poll-interval agent-tasks-poll-interval
                       #'agent-tasks--poll-safely))))

(defun agent-tasks--on-layout-activated (type _frame-or-window persp)
  "Clear the done flag of PERSP's task; show its session the first time.
Runs from `persp-activated-functions' with TYPE frame or window."
  (when-let* (((eq type 'frame))
              (task (gethash (safe-persp-name persp) agent-tasks--tasks)))
    (setf (agent-tasks-task-done task) nil)
    (when (and (agent-tasks--live-p task) (not (agent-tasks-task-shown task)))
      (setf (agent-tasks-task-shown task) t)
      ;; A new layout starts with the previous layout's windows.  pilish's
      ;; input window is dedicated, so clear that before reusing the window.
      (delete-other-windows)
      (set-window-dedicated-p (selected-window) nil)
      (switch-to-buffer (agent-tasks-task-chat-buffer task) nil t)
      (agent-tasks--pilish-show (agent-tasks-task-chat-buffer task)))))

;;;; Close and resume

(defcustom agent-tasks-ignored-changes '("\\`\\.pi/")
  "Regexps for worktree paths whose changes are not the task's work.
Paths are relative to the worktree, as git status prints them."
  :type '(repeat regexp))

(defun agent-tasks--dirty-p (dir)
  "Return non-nil when DIR has changes outside `agent-tasks-ignored-changes'."
  (cl-loop for line in (split-string
                        (agent-tasks--git-ok dir "status" "--porcelain"
                                             "--untracked-files=all")
                        "\n" t)
           for path = (substring line 3)
           thereis (not (cl-some (lambda (re) (string-match-p re path))
                                 agent-tasks-ignored-changes))))

(defun agent-tasks--worktree-state (task)
  "Return (:dirty BOOL :unmerged BOOL) for TASK's worktree and branch."
  (let ((dir (agent-tasks-task-worktree task))
        (branch (agent-tasks-task-branch task)))
    (list :dirty (and (file-directory-p dir) (agent-tasks--dirty-p dir))
          :unmerged (and (agent-tasks--branch-p (agent-tasks-task-repo task) branch)
                         (not (agent-tasks--git-p
                               (agent-tasks-task-repo task) "merge-base"
                               "--is-ancestor" branch
                               (agent-tasks-task-base task)))))))

(defun agent-tasks--close (task remove-worktree)
  "Close TASK: kill its layout and session and forget it.
When REMOVE-WORKTREE is non-nil also remove the worktree and delete
the branch, discarding uncommitted and unmerged work."
  (let ((repo (agent-tasks-task-repo task))
        (dir (agent-tasks-task-worktree task))
        (branch (agent-tasks-task-branch task)))
    (agent-tasks--layout-kill (agent-tasks-task-name task))
    (when (agent-tasks--live-p task)
      (agent-tasks--pilish-kill (agent-tasks-task-chat-buffer task)))
    (when remove-worktree
      (when (file-directory-p dir)
        (agent-tasks--git-ok repo "worktree" "remove" "--force"
                             (directory-file-name dir)))
      (agent-tasks--git-ok repo "worktree" "prune")
      (when (agent-tasks--branch-p repo branch)
        (agent-tasks--git-ok repo "branch" "-D" branch)))
    (remhash (agent-tasks-task-name task) agent-tasks--tasks)
    (agent-tasks--persist)))

(defun agent-tasks--resume (task)
  "Start a live session for dormant TASK in its layout, without switching.
Resume its session file when it exists, else start a fresh session."
  (let* ((file (agent-tasks-task-session-file task))
         (chat (if (and file (file-readable-p file))
                   (save-window-excursion (agent-tasks--pilish-resume file))
                 (agent-tasks--pilish-start (agent-tasks-task-worktree task))))
         (buffers (list chat (agent-tasks--pilish-input chat)))
         (name (agent-tasks-task-name task)))
    (setf (agent-tasks-task-chat-buffer task) chat
          (agent-tasks-task-shown task) nil
          (agent-tasks-task-done task) nil
          (agent-tasks-task-busy-seen task) nil)
    (if (agent-tasks--layout-exists-p name)
        (persp-add-buffer buffers (persp-get-by-name name) nil nil)
      (agent-tasks--layout-create name buffers))
    task))

;;;; Dashboard

(defun agent-tasks--age (created &optional now)
  "Return a short age string for timestamp CREATED relative to NOW."
  (if (null created)
      ""
    (let ((secs (float-time (time-subtract
                             (or now (current-time))
                             (encode-time (parse-time-string created))))))
      (cond ((< secs 60) "<1m")
            ((< secs 3600) (format "%dm" (/ secs 60)))
            ((< secs 86400) (format "%dh" (/ secs 3600)))
            (t (format "%dd" (/ secs 86400)))))))

(defun agent-tasks--status-label (status)
  "Return the dashboard label for STATUS."
  (pcase status
    ('working (propertize "working" 'face 'warning))
    ('done (propertize "● done" 'face 'success))
    ('idle "idle")
    ('exited (propertize "exited" 'face 'error))
    ('dormant (propertize "dormant" 'face 'shadow))
    ('interrupted (propertize "dormant (interrupted)" 'face 'warning))
    ('missing (propertize "missing" 'face 'error))))

(defun agent-tasks--current-branch (dir)
  "Return the checked-out branch of DIR, or \"\"."
  (pcase (and (file-directory-p dir)
              (agent-tasks--git dir "branch" "--show-current"))
    (`(0 . ,branch) branch)
    (_ "")))

(defun agent-tasks--entries ()
  "Return `tabulated-list-entries' for the dashboard."
  (append
   (mapcar
    (lambda (task)
      (list (agent-tasks-task-name task)
            (vector (agent-tasks-task-name task)
                    (agent-tasks--status-label (agent-tasks--status task))
                    (agent-tasks--project-name (agent-tasks-task-repo task))
                    (format "%s (%s)" (agent-tasks-task-branch task)
                            (agent-tasks-task-base task))
                    (agent-tasks--age (agent-tasks-task-created task))
                    (or (agent-tasks-task-parent task) ""))))
    (agent-tasks--task-list))
   (cl-loop for chat in (agent-tasks--pilish-chat-buffers)
            unless (agent-tasks--task-for-chat chat)
            collect
            (let ((dir (buffer-local-value 'default-directory chat)))
              (list chat
                    (vector (propertize (abbreviate-file-name dir) 'face 'shadow)
                            (agent-tasks--status-label
                             (agent-tasks--session-status chat))
                            (agent-tasks--project-name dir)
                            (agent-tasks--current-branch dir)
                            ""
                            (or (agent-tasks--layout-of-buffer chat) "")))))))

(defconst agent-tasks--buffer-name "*agent-tasks*"
  "Name of the dashboard buffer.")

(defvar-keymap agent-tasks-list-mode-map
  :doc "Keymap for `agent-tasks-list-mode'."
  "RET" #'agent-tasks-visit
  "R" #'agent-tasks-resume-all
  "m" #'agent-tasks-magit
  "+" #'agent-tasks-new
  "^" #'agent-tasks-goto-parent
  "k" #'agent-tasks-close)

(define-derived-mode agent-tasks-list-mode tabulated-list-mode "Agent-Tasks"
  "Dashboard of agent tasks and pilish sessions.
\\{agent-tasks-list-mode-map}"
  (setq tabulated-list-format
        [("Task" 24 t) ("Status" 22 t) ("Repo" 14 t) ("Branch (base)" 28 t)
         ("Age" 5 nil) ("Parent" 0 t)]
        tabulated-list-padding 1)
  (add-hook 'tabulated-list-revert-hook
            (lambda () (setq tabulated-list-entries (agent-tasks--entries)))
            nil t)
  (tabulated-list-init-header))

(defun agent-tasks--refresh-dashboard ()
  "Redraw the dashboard if it is visible."
  (when-let* ((buf (get-buffer agent-tasks--buffer-name))
              ((get-buffer-window buf t)))
    (with-current-buffer buf
      (setq tabulated-list-entries (agent-tasks--entries))
      (tabulated-list-print t))))

(add-hook 'agent-tasks-after-poll-hook #'agent-tasks--refresh-dashboard)

;;;###autoload
(defun agent-tasks-list ()
  "Show the agent tasks dashboard."
  (interactive)
  (let ((dir default-directory))
    (with-current-buffer (get-buffer-create agent-tasks--buffer-name)
      (unless (derived-mode-p 'agent-tasks-list-mode)
        (agent-tasks-list-mode))
      (setq default-directory dir)
      (setq tabulated-list-entries (agent-tasks--entries))
      (tabulated-list-print t)
      (pop-to-buffer (current-buffer)))))

(defun agent-tasks--id-at-point ()
  "Return the dashboard row id at point, or signal."
  (or (tabulated-list-get-id) (user-error "No task on this line")))

(defun agent-tasks--visit-task (task)
  "Switch to TASK's layout, resuming its session if needed."
  (pcase (agent-tasks--status task)
    ('missing (user-error "Worktree %s is gone; close the task with k"
                          (agent-tasks-task-worktree task)))
    ((or 'dormant 'interrupted) (agent-tasks--resume task)))
  (let ((name (agent-tasks-task-name task)))
    (unless (agent-tasks--layout-exists-p name)
      (setf (agent-tasks-task-shown task) nil)
      (let ((chat (agent-tasks-task-chat-buffer task)))
        (agent-tasks--layout-create name (list chat (agent-tasks--pilish-input chat)))))
    (agent-tasks--layout-switch name)))

(defun agent-tasks-visit ()
  "Switch to the task or session on this line."
  (interactive)
  (let ((id (agent-tasks--id-at-point)))
    (if (stringp id)
        (agent-tasks--visit-task (gethash id agent-tasks--tasks))
      (let ((layout (agent-tasks--layout-of-buffer id)))
        (when (and layout (not (equal layout persp-nil-name)))
          (agent-tasks--layout-switch layout))
        (agent-tasks--pilish-show id)))))

(defun agent-tasks-resume-all ()
  "Resume every dormant task in the background."
  (interactive)
  (let ((n 0))
    (dolist (task (agent-tasks--task-list))
      (when (memq (agent-tasks--status task) '(dormant interrupted))
        (agent-tasks--resume task)
        (cl-incf n)))
    (agent-tasks--refresh-dashboard)
    (message "agent-tasks: resumed %d task%s" n (if (= n 1) "" "s"))))

(declare-function magit-status "magit-status" (&optional directory cache))

(defun agent-tasks-magit ()
  "Open magit for the worktree on this line."
  (interactive)
  (let ((id (agent-tasks--id-at-point)))
    (magit-status (if (stringp id)
                      (agent-tasks-task-worktree (gethash id agent-tasks--tasks))
                    (buffer-local-value 'default-directory id)))))

(defun agent-tasks-goto-parent ()
  "Move to the parent of the task on this line."
  (interactive)
  (let* ((id (agent-tasks--id-at-point))
         (parent (and (stringp id)
                      (agent-tasks-task-parent (gethash id agent-tasks--tasks))))
         (pos (and parent
                   (save-excursion
                     (goto-char (point-min))
                     (cl-loop until (eobp)
                              when (equal (tabulated-list-get-id) parent)
                              return (point)
                              do (forward-line 1))))))
    (cond (pos (goto-char pos))
          (parent (message "Parent %s is not a task" parent))
          (t (message "No parent")))))

(defun agent-tasks--read-repo ()
  "Read a repo name for a new task; empty means the current repository."
  (let ((name (completing-read
               "Repo (empty for current): "
               (delete-dups
                (cl-loop for p in (agent-tasks--known-projects)
                         when (agent-tasks--main-checkout-dir-p p)
                         collect (agent-tasks--project-name
                                  (expand-file-name p)))))))
    (unless (string-empty-p name) name)))

(defun agent-tasks-new (name repo prompt &optional base)
  "Spawn task NAME in REPO with PROMPT, branching from BASE.
Interactively, ask for BASE only with a prefix argument."
  (interactive
   (list (read-string "Task name: ")
         (agent-tasks--read-repo)
         (read-string "Prompt: ")
         (when current-prefix-arg (read-string "Base branch: "))))
  (let ((result (agent-tasks-spawn :name name :prompt prompt :repo repo
                                   :base (and base (not (string-empty-p base)) base)
                                   :cwd default-directory)))
    (agent-tasks--refresh-dashboard)
    (message "agent-tasks: spawned %s in %s from %s%s"
             name (abbreviate-file-name (plist-get result :worktree))
             (plist-get result :base)
             (if (eq (plist-get result :baseFellBack) t) " (fallback)" ""))))

(defun agent-tasks-close ()
  "Close the task on this line, optionally removing its worktree.
For an untracked session, kill the session."
  (interactive)
  (let ((id (agent-tasks--id-at-point)))
    (if (not (stringp id))
        (when (y-or-n-p (format "Kill pilish session %s? " (buffer-name id)))
          (agent-tasks--pilish-kill id))
      (let* ((task (gethash id agent-tasks--tasks))
             (state (agent-tasks--worktree-state task))
             (dir (abbreviate-file-name (agent-tasks-task-worktree task)))
             (warnings (delq nil (list (and (plist-get state :dirty)
                                            "has uncommitted changes")
                                       (and (plist-get state :unmerged)
                                            (format "is not merged into %s"
                                                    (agent-tasks-task-base task)))))))
        (when (y-or-n-p (format "Close task %s? " id))
          (agent-tasks--close
           task
           (and (file-directory-p dir)
                (if warnings
                    (yes-or-no-p
                     (format "%s %s.  Remove worktree and delete branch %s anyway? "
                             dir (string-join warnings " and ")
                             (agent-tasks-task-branch task)))
                  (y-or-n-p (format "Remove worktree %s and delete branch %s? "
                                    dir (agent-tasks-task-branch task)))))))))
    (agent-tasks--refresh-dashboard)))

(provide 'agent-tasks)
;;; agent-tasks.el ends here
