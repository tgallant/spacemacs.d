;;; agent-tasks-test.el --- Tests for agent-tasks -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with `make test-el'.  Tests create throwaway git repositories under a
;; temporary directory and never start pi.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'agent-tasks)
(require 'server)

;; Never start a real server on the user's socket from tests.
(setq agent-tasks-start-server nil)

;;;; Helpers

(defun agent-tasks-test--git (dir &rest args)
  "Run git ARGS in DIR, signalling on failure."
  (let ((default-directory (file-name-as-directory dir)))
    (with-temp-buffer
      (unless (zerop (apply #'process-file "git" nil t nil args))
        (error "git %S failed: %s" args (buffer-string)))
      (string-trim (buffer-string)))))

(defun agent-tasks-test--make-repo (parent name &optional branch)
  "Create repo NAME under PARENT with one commit on BRANCH (default main)."
  (let ((dir (file-name-as-directory (expand-file-name name parent))))
    (make-directory dir t)
    (agent-tasks-test--git dir "init" "-q" "-b" (or branch "main"))
    (agent-tasks-test--git dir "commit" "-q" "--allow-empty" "-m" "init")
    (file-truename dir)))

(defmacro agent-tasks-test--with-sandbox (var &rest body)
  "Bind VAR to a fresh temp directory with isolated git config, run BODY."
  (declare (indent 1))
  `(let* ((,var (file-name-as-directory
                 (file-truename (make-temp-file "agent-tasks-test" t))))
          (process-environment
           (append (list "GIT_CONFIG_GLOBAL=/dev/null"
                         "GIT_CONFIG_NOSYSTEM=1"
                         "GIT_AUTHOR_NAME=t" "GIT_AUTHOR_EMAIL=t@t"
                         "GIT_COMMITTER_NAME=t" "GIT_COMMITTER_EMAIL=t@t")
                   process-environment)))
     (unwind-protect (progn ,@body)
       (delete-directory ,var t))))

(defun agent-tasks-test--error-message (thunk)
  "Call THUNK and return the message of the error it signals, or nil."
  (condition-case err (progn (funcall thunk) nil)
    (error (error-message-string err))))

;;;; Git layer

(ert-deftest agent-tasks-main-checkout-from-root-subdir-and-worktree ()
  (agent-tasks-test--with-sandbox tmp
    (let ((repo (agent-tasks-test--make-repo tmp "r")))
      (make-directory (expand-file-name "sub" repo))
      (agent-tasks-test--git repo "worktree" "add" "-q" "-b" "wt"
                             (expand-file-name "r-wt" tmp))
      (should (equal (agent-tasks--main-checkout repo) repo))
      (should (equal (agent-tasks--main-checkout (expand-file-name "sub" repo))
                     repo))
      (should (equal (agent-tasks--main-checkout (expand-file-name "r-wt" tmp))
                     repo)))))

(ert-deftest agent-tasks-main-checkout-outside-git-errors ()
  (agent-tasks-test--with-sandbox tmp
    (should (string-match-p "not inside a git repository"
                            (agent-tasks-test--error-message
                             (lambda () (agent-tasks--main-checkout tmp)))))))

(ert-deftest agent-tasks-resolve-base-prefers-main ()
  (agent-tasks-test--with-sandbox tmp
    (let ((repo (agent-tasks-test--make-repo tmp "r")))
      (agent-tasks-test--git repo "branch" "master")
      (should (equal (agent-tasks--resolve-base repo nil) '("main" . nil))))))

(ert-deftest agent-tasks-resolve-base-falls-back-to-master ()
  (agent-tasks-test--with-sandbox tmp
    (let ((repo (agent-tasks-test--make-repo tmp "r" "master")))
      (should (equal (agent-tasks--resolve-base repo nil) '("master" . t))))))

(ert-deftest agent-tasks-resolve-base-uses-origin-head-before-master ()
  (agent-tasks-test--with-sandbox tmp
    (let ((repo (agent-tasks-test--make-repo tmp "r" "master")))
      (agent-tasks-test--git repo "branch" "trunk")
      (agent-tasks-test--git repo "update-ref" "refs/remotes/origin/trunk" "HEAD")
      (agent-tasks-test--git repo "symbolic-ref" "refs/remotes/origin/HEAD"
                             "refs/remotes/origin/trunk")
      (should (equal (agent-tasks--resolve-base repo nil) '("trunk" . t))))))

(ert-deftest agent-tasks-resolve-base-uses-remote-ref-without-local-branch ()
  (agent-tasks-test--with-sandbox tmp
    (let ((repo (agent-tasks-test--make-repo tmp "r" "master")))
      (agent-tasks-test--git repo "update-ref" "refs/remotes/origin/trunk" "HEAD")
      (agent-tasks-test--git repo "symbolic-ref" "refs/remotes/origin/HEAD"
                             "refs/remotes/origin/trunk")
      (should (equal (agent-tasks--resolve-base repo nil)
                     '("origin/trunk" . t))))))

(ert-deftest agent-tasks-resolve-base-explicit ()
  (agent-tasks-test--with-sandbox tmp
    (let ((repo (agent-tasks-test--make-repo tmp "r")))
      (agent-tasks-test--git repo "branch" "dev")
      (should (equal (agent-tasks--resolve-base repo "dev") '("dev" . nil)))
      (should (string-match-p "Base branch nope not found.*dev.*main"
                              (agent-tasks-test--error-message
                               (lambda () (agent-tasks--resolve-base repo "nope"))))))))

(ert-deftest agent-tasks-resolve-base-no-candidate-lists-branches ()
  (agent-tasks-test--with-sandbox tmp
    (let ((repo (agent-tasks-test--make-repo tmp "r" "develop")))
      (should (string-match-p "No main, origin/HEAD or master.*develop"
                              (agent-tasks-test--error-message
                               (lambda () (agent-tasks--resolve-base repo nil))))))))

(ert-deftest agent-tasks-resolve-base-unborn-repo-errors ()
  (agent-tasks-test--with-sandbox tmp
    (let ((repo (expand-file-name "u/" tmp)))
      (make-directory repo)
      (agent-tasks-test--git repo "init" "-q" "-b" "main")
      (should (string-match-p "No main, origin/HEAD or master.*(none)"
                              (agent-tasks-test--error-message
                               (lambda () (agent-tasks--resolve-base repo nil))))))))

(ert-deftest agent-tasks-resolve-repo-defaults-to-cwd-main-checkout ()
  (agent-tasks-test--with-sandbox tmp
    (let ((repo (agent-tasks-test--make-repo tmp "r")))
      (agent-tasks-test--git repo "worktree" "add" "-q" "-b" "wt"
                             (expand-file-name "r-wt" tmp))
      (should (equal (agent-tasks--resolve-repo nil (expand-file-name "r-wt/" tmp) nil)
                     repo)))))

(ert-deftest agent-tasks-resolve-repo-accepts-paths ()
  (agent-tasks-test--with-sandbox tmp
    (let ((repo (agent-tasks-test--make-repo tmp "r")))
      (should (equal (agent-tasks--resolve-repo (directory-file-name repo) tmp nil)
                     repo))
      (should (string-match-p "not inside a git repository"
                              (agent-tasks-test--error-message
                               (lambda () (agent-tasks--resolve-repo tmp tmp nil))))))))

(ert-deftest agent-tasks-resolve-repo-by-project-name ()
  (agent-tasks-test--with-sandbox tmp
    (let* ((a (agent-tasks-test--make-repo tmp "one/tmd"))
           (b (agent-tasks-test--make-repo tmp "two/tmd"))
           (c (agent-tasks-test--make-repo tmp "gw"))
           (wt (expand-file-name "gw-feature/" tmp))
           (projects (list a b c wt)))
      (agent-tasks-test--git c "worktree" "add" "-q" "-b" "feature" wt)
      (should (equal (agent-tasks--resolve-repo "gw" tmp projects) c))
      (should (string-match-p "Unknown repo gw-feature"
                              (agent-tasks-test--error-message
                               (lambda () (agent-tasks--resolve-repo "gw-feature" tmp projects)))))
      (let ((msg (agent-tasks-test--error-message
                  (lambda () (agent-tasks--resolve-repo "tmd" tmp projects)))))
        (should (string-match-p "Ambiguous repo tmd" msg))
        (should (string-match-p (regexp-quote (abbreviate-file-name a)) msg))
        (should (string-match-p (regexp-quote (abbreviate-file-name b)) msg)))
      (let ((msg (agent-tasks-test--error-message
                  (lambda ()
                    (agent-tasks--resolve-repo
                     "nope" tmp
                     (append projects
                             (list "./" (expand-file-name "gone/" tmp)
                                   (concat c "./")
                                   (file-name-as-directory tmp))))))))
        (should (string-match-p "Unknown repo nope; pass a path or one of: tmd, gw\\'"
                                msg))))))

(ert-deftest agent-tasks-validate-name ()
  (agent-tasks-test--with-sandbox tmp
    (let ((repo (agent-tasks-test--make-repo tmp "r")))
      (agent-tasks-test--git repo "branch" "taken")
      (make-directory (expand-file-name "r-dirtaken" tmp))
      (should-not (agent-tasks--validate-name repo "fix-login-2"))
      (dolist (bad '("" "has space" "-lead" "a/b" "a..b"))
        (should (string-match-p "Invalid task name"
                                (agent-tasks-test--error-message
                                 (lambda () (agent-tasks--validate-name repo bad))))))
      (should (string-match-p "Branch taken already exists"
                              (agent-tasks-test--error-message
                               (lambda () (agent-tasks--validate-name repo "taken")))))
      (should (string-match-p "already exists"
                              (agent-tasks-test--error-message
                               (lambda () (agent-tasks--validate-name repo "dirtaken"))))))))

(ert-deftest agent-tasks-create-worktree ()
  (agent-tasks-test--with-sandbox tmp
    (let* ((repo (agent-tasks-test--make-repo tmp "r"))
           (dir (agent-tasks--create-worktree repo "feat" "main")))
      (should (equal dir (expand-file-name "r-feat/" tmp)))
      (should (file-directory-p dir))
      (should (equal (agent-tasks-test--git dir "branch" "--show-current") "feat"))
      (should (equal (agent-tasks-test--git dir "rev-parse" "HEAD")
                     (agent-tasks-test--git repo "rev-parse" "main"))))))

;;;; Registry and persistence

(defun agent-tasks-test--task (&rest overrides)
  "Return a task with sample values, applying plist OVERRIDES."
  (agent-tasks--task-from-plist
   (append overrides
           (list :name "t1" :repo "/r/" :worktree "/r-t1/" :branch "t1"
                 :base "main" :parent "Default" :depth 1
                 :created "2026-10-14T22:31:00" :prompt "do it"
                 :session-file "/s.jsonl" :last-status 'working))))

(ert-deftest agent-tasks-task-plist-round-trip ()
  (let ((task (agent-tasks-test--task)))
    (setf (agent-tasks-task-done task) t)
    (let ((plist (agent-tasks--task-to-plist task)))
      (should (equal (plist-get plist :name) "t1"))
      (should (eq (plist-get plist :last-status) 'working))
      (should-not (plist-member plist :done))
      (should (equal (agent-tasks--task-to-plist
                      (agent-tasks--task-from-plist plist))
                     plist)))))

(ert-deftest agent-tasks-save-and-load ()
  (agent-tasks-test--with-sandbox tmp
    (let ((agent-tasks-file (expand-file-name "sub/tasks.eld" tmp))
          (tasks (list (agent-tasks-test--task)
                       (agent-tasks-test--task :name "t2" :prompt "quote \" and\nnewline"))))
      (agent-tasks--save tasks)
      (should (file-exists-p agent-tasks-file))
      (should-not (directory-files (file-name-directory agent-tasks-file)
                                   nil "\\.tmp"))
      (should (equal (mapcar #'agent-tasks--task-to-plist (agent-tasks--load))
                     (mapcar #'agent-tasks--task-to-plist tasks))))))

(ert-deftest agent-tasks-load-missing-or-corrupt-file ()
  (agent-tasks-test--with-sandbox tmp
    (let ((agent-tasks-file (expand-file-name "tasks.eld" tmp)))
      (should-not (agent-tasks--load))
      (with-temp-file agent-tasks-file (insert "((:name \"x\""))
      (let ((inhibit-message t))
        (should-not (agent-tasks--load))))))

;;;; Spawn

(require 'persp-mode)
(setq persp-auto-resume-time -1
      persp-auto-save-opt 0
      ;; Never prompt from batch when killing buffers of other layouts.
      persp-kill-foreign-buffer-behaviour 'kill)
(persp-mode 1)

(defvar agent-tasks-test--sent nil
  "List of (CHAT-BUFFER-NAME . TEXT) sent through the stubbed adapter.")

(defvar agent-tasks-test--session-files nil
  "Alist of (CHAT-BUFFER . SESSION-FILE) for the stubbed adapter.")

(defun agent-tasks-test--fake-session (dir)
  "Create fake chat and input buffers for DIR; return the chat buffer."
  (let ((chat (generate-new-buffer (format "*fake-chat:%s*" dir)))
        (input (generate-new-buffer (format "*fake-input:%s*" dir))))
    (with-current-buffer chat
      (setq-local agent-tasks-test--input input)
      (setq default-directory dir))
    chat))

(defmacro agent-tasks-test--with-spawn-env (var &rest body)
  "Run BODY with VAR bound to a sandbox, a fresh registry and a stub pilish."
  (declare (indent 1))
  `(agent-tasks-test--with-sandbox ,var
     (let ((agent-tasks--tasks (make-hash-table :test #'equal))
           (agent-tasks-file (expand-file-name "tasks.eld" ,var))
           (agent-tasks-max-depth 3)
           (agent-tasks-max-live 8)
           (agent-tasks-test--sent nil)
           (agent-tasks-test--session-files nil)
           (layouts-before (persp-names-current-frame-fast-ordered))
           (fake-chats nil))
       (cl-letf (((symbol-function 'agent-tasks--pilish-start)
                  (lambda (dir &optional _model)
                    (car (push (agent-tasks-test--fake-session dir) fake-chats))))
                 ((symbol-function 'agent-tasks--pilish-input)
                  (lambda (chat) (buffer-local-value 'agent-tasks-test--input chat)))
                 ((symbol-function 'agent-tasks--pilish-send)
                  (lambda (chat text)
                    (push (cons (buffer-name chat) text) agent-tasks-test--sent)))
                 ((symbol-function 'agent-tasks--pilish-chat-buffers)
                  (lambda ()
                    (seq-filter #'buffer-live-p
                                (append fake-chats
                                        (mapcar #'car agent-tasks-test--session-files)))))
                 ((symbol-function 'agent-tasks--pilish-session-file)
                  (lambda (chat)
                    (alist-get chat agent-tasks-test--session-files))))
         (unwind-protect (progn ,@body)
           (dolist (name (persp-names-current-frame-fast-ordered))
             (unless (member name layouts-before)
               (persp-kill name t)))
           (dolist (b fake-chats)
             (when (buffer-live-p b)
               (kill-buffer (buffer-local-value 'agent-tasks-test--input b))
               (kill-buffer b))))))))

(defvar-local agent-tasks-test--input nil)
(defvar-local agent-tasks-test--status 'idle)
(defvar-local agent-tasks-test--proc-live t)
(defvar agent-tasks-test--shown nil)
(defvar agent-tasks-test--notified nil)

(defmacro agent-tasks-test--with-status-env (var &rest body)
  "Like `agent-tasks-test--with-spawn-env' with status stubs too."
  (declare (indent 1))
  `(agent-tasks-test--with-spawn-env ,var
     (let ((agent-tasks-test--shown nil)
           (agent-tasks-test--notified nil)
           (agent-tasks-notify-function
            (lambda (task) (push (agent-tasks-task-name task)
                                 agent-tasks-test--notified))))
       (cl-letf (((symbol-function 'agent-tasks--pilish-status)
                  (lambda (chat) (buffer-local-value 'agent-tasks-test--status chat)))
                 ((symbol-function 'agent-tasks--pilish-process-live-p)
                  (lambda (chat) (buffer-local-value 'agent-tasks-test--proc-live chat)))
                 ((symbol-function 'agent-tasks--pilish-show)
                  (lambda (chat) (push chat agent-tasks-test--shown))))
         ,@body))))

(defun agent-tasks-test--register (name dir &rest plist)
  "Register task NAME with worktree DIR and a fake live session.
PLIST overrides task slots; pass :chat-buffer nil for no session."
  (let* ((chat (if (plist-member plist :chat-buffer)
                   (plist-get plist :chat-buffer)
                 (agent-tasks--pilish-start dir)))
         (task (agent-tasks--task-from-plist
                (append plist (list :name name :worktree dir :branch name
                                    :base "main" :depth 1
                                    :created (agent-tasks--timestamp)
                                    :last-status 'working)))))
    (setf (agent-tasks-task-chat-buffer task) chat)
    (puthash name task agent-tasks--tasks)))

(defun agent-tasks-test--set-status (task status)
  "Set the fake pilish STATUS of TASK's session."
  (with-current-buffer (agent-tasks-task-chat-buffer task)
    (setq agent-tasks-test--status status)))

(ert-deftest agent-tasks-spawn-creates-worktree-layout-and-session ()
  (agent-tasks-test--with-spawn-env tmp
    (let* ((repo (agent-tasks-test--make-repo tmp "r"))
           (current (safe-persp-name (get-current-persp)))
           (result (agent-tasks-spawn :name "feat" :prompt "do the thing"
                                      :cwd repo))
           (task (gethash "feat" agent-tasks--tasks))
           (chat (agent-tasks-task-chat-buffer task)))
      (should (equal (plist-get result :task) "feat"))
      (should (equal (plist-get result :worktree) (expand-file-name "r-feat/" tmp)))
      (should (equal (plist-get result :branch) "feat"))
      (should (equal (plist-get result :base) "main"))
      (should (eq (plist-get result :baseFellBack) :false))
      (should (file-directory-p (expand-file-name "r-feat/" tmp)))
      (should (persp-with-name-exists-p "feat"))
      (should (equal (safe-persp-name (get-current-persp)) current))
      (should (persp-contain-buffer-p chat (persp-get-by-name "feat")))
      (should (persp-contain-buffer-p (agent-tasks--pilish-input chat)
                                      (persp-get-by-name "feat")))
      (should (equal (mapcar #'car agent-tasks-test--sent) (list (buffer-name chat))))
      (let ((sent (cdar agent-tasks-test--sent)))
        (should (string-match-p (regexp-quote (expand-file-name "r-feat/" tmp)) sent))
        (should (string-match-p "branch feat (from main), created for this task" sent))
        (should (string-suffix-p "\n\ndo the thing" sent)))
      (should (equal (agent-tasks-task-prompt task) "do the thing"))
      (should (equal (agent-tasks-task-depth task) 1))
      (should-not (agent-tasks-task-parent task))
      (should (equal (mapcar #'agent-tasks-task-name (agent-tasks--load))
                     '("feat"))))))

(ert-deftest agent-tasks-spawn-reports-base-fallback ()
  (agent-tasks-test--with-spawn-env tmp
    (let* ((repo (agent-tasks-test--make-repo tmp "r" "master"))
           (result (agent-tasks-spawn :name "feat" :prompt "p" :repo repo :cwd tmp)))
      (should (equal (plist-get result :base) "master"))
      (should (eq (plist-get result :baseFellBack) t)))))

(ert-deftest agent-tasks-spawn-parent-from-session-file ()
  (agent-tasks-test--with-spawn-env tmp
    (let* ((repo (agent-tasks-test--make-repo tmp "r"))
           (_ (agent-tasks-spawn :name "parent" :prompt "p" :cwd repo))
           (parent-chat (agent-tasks-task-chat-buffer
                         (gethash "parent" agent-tasks--tasks))))
      (push (cons parent-chat "/parent.jsonl") agent-tasks-test--session-files)
      (agent-tasks-spawn :name "child" :prompt "p" :cwd repo
                         :parent-session "/parent.jsonl")
      (let ((child (gethash "child" agent-tasks--tasks)))
        (should (equal (agent-tasks-task-parent child) "parent"))
        (should (equal (agent-tasks-task-depth child) 2))))))

(ert-deftest agent-tasks-spawn-parent-from-untracked-session-layout ()
  (agent-tasks-test--with-spawn-env tmp
    (let ((repo (agent-tasks-test--make-repo tmp "r"))
          (other (generate-new-buffer "*untracked-chat*")))
      (unwind-protect
          (progn
            (persp-add-buffer other (persp-add-new "side-layout") nil nil)
            (push (cons other "/side.jsonl") agent-tasks-test--session-files)
            (agent-tasks-spawn :name "child" :prompt "p" :cwd repo
                               :parent-session "/side.jsonl")
            (let ((child (gethash "child" agent-tasks--tasks)))
              (should (equal (agent-tasks-task-parent child) "side-layout"))
              (should (equal (agent-tasks-task-depth child) 1))))
        (kill-buffer other)))))

(ert-deftest agent-tasks-spawn-enforces-max-depth ()
  (agent-tasks-test--with-spawn-env tmp
    (let ((repo (agent-tasks-test--make-repo tmp "r"))
          (agent-tasks-max-depth 1))
      (agent-tasks-spawn :name "parent" :prompt "p" :cwd repo)
      (push (cons (agent-tasks-task-chat-buffer (gethash "parent" agent-tasks--tasks))
                  "/parent.jsonl")
            agent-tasks-test--session-files)
      (should (string-match-p "depth limit"
                              (agent-tasks-test--error-message
                               (lambda ()
                                 (agent-tasks-spawn :name "child" :prompt "p" :cwd repo
                                                    :parent-session "/parent.jsonl")))))
      (should-not (file-exists-p (expand-file-name "r-child" tmp))))))

(ert-deftest agent-tasks-spawn-enforces-max-live ()
  (agent-tasks-test--with-spawn-env tmp
    (let ((repo (agent-tasks-test--make-repo tmp "r"))
          (agent-tasks-max-live 1))
      (agent-tasks-spawn :name "one" :prompt "p" :cwd repo)
      (should (string-match-p "1 live tasks"
                              (agent-tasks-test--error-message
                               (lambda ()
                                 (agent-tasks-spawn :name "two" :prompt "p" :cwd repo))))))))

(ert-deftest agent-tasks-spawn-rejects-existing-layout-or-task ()
  (agent-tasks-test--with-spawn-env tmp
    (let ((repo (agent-tasks-test--make-repo tmp "r")))
      (persp-add-new "busy")
      (should (string-match-p "Layout busy already exists"
                              (agent-tasks-test--error-message
                               (lambda ()
                                 (agent-tasks-spawn :name "busy" :prompt "p" :cwd repo)))))
      (should (string-match-p "empty prompt"
                              (agent-tasks-test--error-message
                               (lambda ()
                                 (agent-tasks-spawn :name "x" :prompt "  " :cwd repo))))))))

(ert-deftest agent-tasks-spawn-from-file ()
  (agent-tasks-test--with-spawn-env tmp
    (let* ((repo (agent-tasks-test--make-repo tmp "r"))
           (req (expand-file-name "req.json" tmp)))
      (with-temp-file req
        (insert (json-serialize (list :name "feat" :prompt "p" :cwd repo))))
      (let ((reply (json-parse-string (agent-tasks-spawn-from-file req)
                                      :object-type 'plist)))
        (should (equal (plist-get reply :task) "feat"))
        (should-not (file-exists-p req)))
      (with-temp-file req
        (insert (json-serialize (list :name "bad name" :prompt "p" :cwd repo))))
      (let ((reply (json-parse-string (agent-tasks-spawn-from-file req)
                                      :object-type 'plist)))
        (should (string-match-p "Invalid task name" (plist-get reply :error)))))))

;;;; Mode

(ert-deftest agent-tasks-mode-loads-persisted-tasks-and-installs-hooks ()
  (agent-tasks-test--with-status-env tmp
    (agent-tasks-test--register "live" tmp)
    (agent-tasks--save (list (agent-tasks-test--task :name "live" :prompt "stale")
                             (agent-tasks-test--task :name "old")))
    (unwind-protect
        (progn
          (agent-tasks-mode 1)
          (should (equal (sort (hash-table-keys agent-tasks--tasks) #'string<)
                         '("live" "old")))
          (should-not (equal (agent-tasks-task-prompt (gethash "live" agent-tasks--tasks))
                             "stale"))
          (should (memq #'agent-tasks--on-layout-activated persp-activated-functions))
          (should (memq 'agent-tasks--mode-line global-mode-string))
          (should (timerp agent-tasks--timer)))
      (agent-tasks-mode -1))
    (should-not (memq #'agent-tasks--on-layout-activated persp-activated-functions))
    (should-not (memq 'agent-tasks--mode-line global-mode-string))
    (should-not agent-tasks--timer)))

(ert-deftest agent-tasks-mode-starts-emacs-server ()
  "spawn_task reaches Emacs through emacsclient, so the server must run."
  (agent-tasks-test--with-status-env tmp
    (let ((started 0) (running nil) (agent-tasks-start-server t))
      (cl-letf (((symbol-function 'server-running-p) (lambda (&rest _) running))
                ((symbol-function 'server-start)
                 (lambda (&rest _) (cl-incf started) (setq running t))))
        (unwind-protect
            (progn (agent-tasks-mode 1)
                   (agent-tasks-mode 1)
                   (should (= started 1))
                   (let ((agent-tasks-start-server nil) (running nil))
                     (agent-tasks-mode 1))
                   (should (= started 1)))
          (agent-tasks-mode -1))))))

;;;; Status

(ert-deftest agent-tasks-derive-status ()
  (agent-tasks-test--with-status-env tmp
    (let ((task (agent-tasks-test--register "t" tmp)))
      (dolist (s '(sending streaming compacting))
        (agent-tasks-test--set-status task s)
        (should (eq (agent-tasks--status task) 'working)))
      (agent-tasks-test--set-status task 'idle)
      (should (eq (agent-tasks--status task) 'idle))
      (setf (agent-tasks-task-done task) t)
      (should (eq (agent-tasks--status task) 'done))
      (with-current-buffer (agent-tasks-task-chat-buffer task)
        (setq agent-tasks-test--proc-live nil))
      (should (eq (agent-tasks--status task) 'exited)))
    (let ((task (agent-tasks-test--register "d" tmp :chat-buffer nil
                                            :last-status 'idle)))
      (should (eq (agent-tasks--status task) 'dormant))
      (setf (agent-tasks-task-last-status task) 'working)
      (should (eq (agent-tasks--status task) 'interrupted))
      (setf (agent-tasks-task-worktree task) (expand-file-name "gone/" tmp))
      (should (eq (agent-tasks--status task) 'missing)))))

(ert-deftest agent-tasks-poll-marks-done-once-and-notifies ()
  (agent-tasks-test--with-status-env tmp
    (let ((task (agent-tasks-test--register "t" tmp)))
      (agent-tasks-test--set-status task 'streaming)
      (agent-tasks--poll)
      (should-not (agent-tasks-task-done task))
      (agent-tasks-test--set-status task 'idle)
      (agent-tasks--poll)
      (agent-tasks--poll)
      (should (agent-tasks-task-done task))
      (should (eq (agent-tasks-task-last-status task) 'idle))
      (should (equal agent-tasks-test--notified '("t")))
      (should (eq (plist-get (agent-tasks--task-to-plist (car (agent-tasks--load)))
                             :last-status)
                  'idle)))))

(ert-deftest agent-tasks-poll-catches-turn-shorter-than-interval ()
  (agent-tasks-test--with-status-env tmp
    (let* ((task (agent-tasks-test--register "t" tmp :last-status 'idle))
           (chat (agent-tasks-task-chat-buffer task))
           (scheduled nil))
      (cl-letf (((symbol-function 'run-at-time)
                 (lambda (&rest args) (push args scheduled))))
        ;; A whole turn happens between two polls.
        (agent-tasks--status-watcher 'pilish--status 'streaming 'set chat)
        (agent-tasks--status-watcher 'pilish--status 'idle 'set chat))
      (should (= (length scheduled) 1))
      (agent-tasks--poll)
      (should (agent-tasks-task-done task))
      (should (equal agent-tasks-test--notified '("t")))
      (setf (agent-tasks-task-done task) nil)
      (agent-tasks--poll)
      (should-not (agent-tasks-task-done task)))))

(ert-deftest agent-tasks-status-watcher-ignores-untracked-buffers ()
  (agent-tasks-test--with-status-env tmp
    (with-temp-buffer
      (cl-letf (((symbol-function 'run-at-time) (lambda (&rest _) (error "scheduled"))))
        (agent-tasks--status-watcher 'pilish--status 'idle 'set (current-buffer))
        (agent-tasks--status-watcher 'pilish--status 'idle 'set nil)))))

(ert-deftest agent-tasks-status-watcher-never-signals ()
  "The watcher runs inside pilish's own `setq'; an error would break pilish."
  (cl-letf (((symbol-function 'agent-tasks--task-for-chat)
             (lambda (_) (error "broken"))))
    (with-temp-buffer
      (let ((inhibit-message t))
        (agent-tasks--status-watcher 'pilish--status 'streaming 'set
                                     (current-buffer))))))

(ert-deftest agent-tasks-poll-skips-done-for-current-layout ()
  (agent-tasks-test--with-status-env tmp
    (let ((task (agent-tasks-test--register "t" tmp)))
      (agent-tasks-test--set-status task 'idle)
      (cl-letf (((symbol-function 'agent-tasks--current-layout) (lambda () "t")))
        (agent-tasks--poll))
      (should-not (agent-tasks-task-done task))
      (should-not agent-tasks-test--notified))))

(ert-deftest agent-tasks-poll-records-session-file ()
  (agent-tasks-test--with-status-env tmp
    (let ((task (agent-tasks-test--register "t" tmp)))
      (push (cons (agent-tasks-task-chat-buffer task) "/new.jsonl")
            agent-tasks-test--session-files)
      (agent-tasks--poll)
      (should (equal (agent-tasks-task-session-file task) "/new.jsonl"))
      (should (equal (plist-get (agent-tasks--task-to-plist (car (agent-tasks--load)))
                                :session-file)
                     "/new.jsonl")))))

(ert-deftest agent-tasks-layout-activation-clears-done-and-shows-once ()
  (agent-tasks-test--with-status-env tmp
    (let* ((task (agent-tasks-test--register "t" tmp))
           (persp (persp-add-new "t")))
      (setf (agent-tasks-task-done task) t)
      (agent-tasks--on-layout-activated 'frame (selected-frame) persp)
      (agent-tasks--on-layout-activated 'frame (selected-frame) persp)
      (should-not (agent-tasks-task-done task))
      (should (equal agent-tasks-test--shown
                     (list (agent-tasks-task-chat-buffer task)))))))

(ert-deftest agent-tasks-layout-activation-replaces-dedicated-windows ()
  "pilish's input window is dedicated; it must not survive into the new layout."
  (agent-tasks-test--with-status-env tmp
    (let* ((task (agent-tasks-test--register "t" tmp))
           (chat (agent-tasks-task-chat-buffer task))
           (other (get-buffer-create "*other-input*"))
           (seen nil))
      (save-window-excursion
        (delete-other-windows)
        (let ((input-win (split-window-below)))
          (set-window-buffer input-win other)
          (set-window-dedicated-p input-win 'side)
          (select-window input-win))
        (cl-letf (((symbol-function 'agent-tasks--pilish-show)
                   (lambda (c)
                     (setq seen (mapcar (lambda (w) (list (window-buffer w)
                                                          (window-dedicated-p w)))
                                        (window-list)))
                     (push c agent-tasks-test--shown))))
          (agent-tasks--on-layout-activated 'frame (selected-frame)
                                            (persp-add-new "t"))))
      (kill-buffer other)
      (should (equal seen (list (list chat nil)))))))

(ert-deftest agent-tasks-mode-line-string ()
  (agent-tasks-test--with-status-env tmp
    (should (equal (agent-tasks--mode-line-string) ""))
    (let ((a (agent-tasks-test--register "a" tmp))
          (b (agent-tasks-test--register "b" tmp))
          (c (agent-tasks-test--register "c" tmp)))
      (agent-tasks-test--set-status a 'streaming)
      (agent-tasks-test--set-status b 'streaming)
      (agent-tasks-test--set-status c 'idle)
      (setf (agent-tasks-task-done c) t)
      (should (equal (agent-tasks--mode-line-string) " ⚙2 ●1"))
      (agent-tasks-test--set-status a 'idle)
      (agent-tasks-test--set-status b 'idle)
      (should (equal (agent-tasks--mode-line-string) " ●1")))))

;;;; Dashboard

(ert-deftest agent-tasks-dashboard-keys-work-under-evil ()
  "Evil's motion state must not shadow the dashboard's keys."
  (skip-unless (require 'evil nil t))
  (let ((was-on (bound-and-true-p evil-mode)))
    (unwind-protect
        (progn
          (evil-mode 1)
          (with-temp-buffer
            (agent-tasks-list-mode)
            (evil-normalize-keymaps)
            (should (eq evil-state 'motion))
            (dolist (binding '(("RET" . agent-tasks-visit)
                               ("R" . agent-tasks-resume-all)
                               ("m" . agent-tasks-magit)
                               ("+" . agent-tasks-new)
                               ("^" . agent-tasks-goto-parent)
                               ("d" . agent-tasks-close)
                               ("gr" . revert-buffer)
                               ("q" . quit-window)
                               ;; Navigation stays Vim-like.
                               ("j" . evil-next-line)
                               ("k" . evil-previous-line)
                               ("gg" . evil-goto-first-line)))
              (should (equal (cons (car binding) (key-binding (kbd (car binding))))
                             binding)))))
      (unless was-on (evil-mode -1)))))

(ert-deftest agent-tasks-dashboard-close-key-without-evil ()
  (with-temp-buffer
    (agent-tasks-list-mode)
    (should (eq (lookup-key agent-tasks-list-mode-map "k") #'agent-tasks-close))
    (should (eq (lookup-key agent-tasks-list-mode-map "d") #'agent-tasks-close))))

(ert-deftest agent-tasks-age ()
  (let ((now (encode-time (parse-time-string "2026-10-14T12:00:00"))))
    (should (equal (agent-tasks--age "2026-10-14T11:59:30" now) "<1m"))
    (should (equal (agent-tasks--age "2026-10-14T11:55:00" now) "5m"))
    (should (equal (agent-tasks--age "2026-10-14T09:00:00" now) "3h"))
    (should (equal (agent-tasks--age "2026-10-11T12:00:00" now) "3d"))
    (should (equal (agent-tasks--age nil now) ""))))

(defun agent-tasks-test--row (entries id)
  "Return the columns of ENTRIES for ID as plain strings."
  (mapcar #'substring-no-properties (append (cadr (assoc id entries)) nil)))

(ert-deftest agent-tasks-entries-include-tasks-and-untracked-sessions ()
  (agent-tasks-test--with-status-env tmp
    (let* ((repo (agent-tasks-test--make-repo tmp "proj"))
           (task (agent-tasks-test--register "feat" (expand-file-name "proj-feat/" tmp)
                                             :repo repo :parent "Default"))
           (untracked (agent-tasks--pilish-start repo))
           (side-wt (expand-file-name "proj-side/" tmp))
           (plain-dir (file-name-as-directory (expand-file-name "notes" tmp))))
      (make-directory (agent-tasks-task-worktree task))
      (agent-tasks-test--set-status task 'streaming)
      (agent-tasks-test--register "old" (expand-file-name "proj-old/" tmp)
                                  :repo repo :chat-buffer nil :last-status 'working)
      (make-directory (expand-file-name "proj-old/" tmp))
      (agent-tasks-test--git repo "worktree" "add" "-q" "-b" "side" side-wt)
      (make-directory plain-dir)
      (let* ((in-worktree (agent-tasks--pilish-start side-wt))
             (outside-git (agent-tasks--pilish-start plain-dir))
             (entries (agent-tasks--entries)))
        ;; A task's branch is its name, so only its base is shown.
        (should (equal (agent-tasks-test--row entries "feat")
                       '("feat" "working" "proj" "from main" "default" "<1m" "Default")))
        (should (equal (nth 1 (agent-tasks-test--row entries "old"))
                       "dormant (interrupted)"))
        ;; Untracked sessions: no age or parent; repo comes from git.
        (should (equal (agent-tasks-test--row entries untracked)
                       (list (abbreviate-file-name repo) "idle" "proj" "main" "" "" "")))
        (should (equal (agent-tasks-test--row entries in-worktree)
                       (list (abbreviate-file-name side-wt) "idle" "proj" "side" "" "" "")))
        (should (equal (agent-tasks-test--row entries outside-git)
                       (list (abbreviate-file-name plain-dir) "idle" "" "" "" "" "")))
        (should (= (length entries) 5))))))

(ert-deftest agent-tasks-column-widths-fit-content ()
  (let ((entries (list (list "a" (vector "task-model-selection" "working" ".spacemacs.d"
                                         "from master" "default" "6m" ""))
                       (list "b" (vector "~/src/cmt/" "dormant (interrupted)" "cmt"
                                         "fix/search-relevance" "" "" "Default")))))
    ;; Each column is as wide as its widest cell or header.
    (should (equal (agent-tasks--column-widths entries 200)
                   '(20 21 12 20 7 3 7)))
    ;; Too narrow: the Task column gives way first, never below its header.
    ;; A row is 1 padding + columns + 6 separators, and 1 column stays free.
    (should (equal (agent-tasks--column-widths entries 90)
                   '(12 21 12 20 7 3 7)))
    (should (equal (agent-tasks--column-widths entries 10)
                   '(4 21 12 20 7 3 7)))))

(ert-deftest agent-tasks-dashboard-shows-every-cell-in-full ()
  (agent-tasks-test--with-status-env tmp
    (let ((repo (agent-tasks-test--make-repo tmp "proj")))
      (agent-tasks-test--register "task-model-selection"
                                  (expand-file-name "proj-task-model-selection/" tmp)
                                  :repo repo :base "master")
      (make-directory (expand-file-name "proj-task-model-selection/" tmp))
      (with-temp-buffer
        (agent-tasks-list-mode)
        (agent-tasks--print)
        (should (string-match-p "task-model-selection +idle +proj +from master +default +<1m"
                                (buffer-string)))
        (should-not (string-match-p "\\.\\.\\.\\|\u2026" (buffer-string)))))))

(ert-deftest agent-tasks-worktree-state ()
  (agent-tasks-test--with-spawn-env tmp
    (let* ((repo (agent-tasks-test--make-repo tmp "r"))
           (wt (agent-tasks--create-worktree repo "feat" "main"))
           (task (agent-tasks-test--register "feat" wt :repo repo :chat-buffer nil)))
      (should (equal (agent-tasks--worktree-state task) '(:dirty nil :unmerged nil)))
      ;; pi extensions keep state under .pi/; that is not the task's work.
      (make-directory (expand-file-name ".pi" wt))
      (with-temp-file (expand-file-name ".pi/superpowers-state.json" wt) (insert "{}"))
      (should (equal (agent-tasks--worktree-state task) '(:dirty nil :unmerged nil)))
      (with-temp-file (expand-file-name "new.txt" wt) (insert "x"))
      (should (equal (agent-tasks--worktree-state task) '(:dirty t :unmerged nil)))
      (agent-tasks-test--git wt "add" "new.txt")
      (agent-tasks-test--git wt "commit" "-q" "-m" "work")
      (should (equal (agent-tasks--worktree-state task) '(:dirty nil :unmerged t))))))

(ert-deftest agent-tasks-close-removes-layout-session-and-worktree ()
  (agent-tasks-test--with-status-env tmp
    (let* ((repo (agent-tasks-test--make-repo tmp "r"))
           (_ (agent-tasks-spawn :name "feat" :prompt "p" :cwd repo))
           (task (gethash "feat" agent-tasks--tasks))
           (chat (agent-tasks-task-chat-buffer task))
           (killed nil))
      (with-temp-file (expand-file-name "dirty.txt" (agent-tasks-task-worktree task))
        (insert "x"))
      (cl-letf (((symbol-function 'agent-tasks--pilish-kill)
                 (lambda (c) (push c killed) (kill-buffer c))))
        (agent-tasks--close task t))
      (should (equal killed (list chat)))
      (should-not (persp-with-name-exists-p "feat"))
      (should-not (file-exists-p (agent-tasks-task-worktree task)))
      (should-not (agent-tasks--branch-p repo "feat"))
      (should-not (gethash "feat" agent-tasks--tasks))
      (should-not (agent-tasks--load)))))

(ert-deftest agent-tasks-close-can-keep-worktree ()
  (agent-tasks-test--with-status-env tmp
    (let* ((repo (agent-tasks-test--make-repo tmp "r"))
           (_ (agent-tasks-spawn :name "feat" :prompt "p" :cwd repo))
           (task (gethash "feat" agent-tasks--tasks)))
      (cl-letf (((symbol-function 'agent-tasks--pilish-kill) #'kill-buffer))
        (agent-tasks--close task nil))
      (should (file-directory-p (agent-tasks-task-worktree task)))
      (should (agent-tasks--branch-p repo "feat"))
      (should-not (gethash "feat" agent-tasks--tasks)))))

(ert-deftest agent-tasks-resume-in-background ()
  (agent-tasks-test--with-status-env tmp
    (let* ((file (expand-file-name "old.jsonl" tmp))
           (task (agent-tasks-test--register "old" tmp :chat-buffer nil
                                             :session-file file
                                             :last-status 'idle))
           (current (agent-tasks--current-layout))
           (resumed nil))
      (with-temp-file file (insert "{}\n"))
      (cl-letf (((symbol-function 'agent-tasks--pilish-resume)
                 (lambda (file &optional _model)
                   (push file resumed)
                   (agent-tasks--pilish-start tmp))))
        (agent-tasks--resume task))
      (should (equal resumed (list file)))
      (should (agent-tasks--live-p task))
      (should (persp-contain-buffer-p (agent-tasks-task-chat-buffer task)
                                      (persp-get-by-name "old")))
      (should (equal (agent-tasks--current-layout) current))
      (should-not (agent-tasks-task-shown task))
      (should (eq (agent-tasks--status task) 'idle)))))

(ert-deftest agent-tasks-resume-without-session-file-starts-fresh ()
  (agent-tasks-test--with-status-env tmp
    (let ((task (agent-tasks-test--register "old" tmp :chat-buffer nil
                                            :session-file "/gone.jsonl"
                                            :last-status 'idle)))
      (cl-letf (((symbol-function 'agent-tasks--pilish-resume)
                 (lambda (_) (error "should not resume"))))
        (agent-tasks--resume task))
      (should (agent-tasks--live-p task))
      (should-not agent-tasks-test--sent))))

;;;; Model selection

(ert-deftest agent-tasks-model-spawn-json-and-persistence ()
  (agent-tasks-test--with-spawn-env tmp
    (let* ((repo (agent-tasks-test--make-repo tmp "r"))
           (file (expand-file-name "request.json" tmp))
           (model "openai-codex/gpt-6.1-sol:high")
           (started nil))
      (cl-letf (((symbol-function 'agent-tasks--pilish-start)
                 (lambda (dir &optional model)
                   (push model started)
                   (car (push (agent-tasks-test--fake-session dir) fake-chats)))))
        (with-temp-file file
          (insert (json-serialize (list :name "pinned" :prompt "p" :cwd repo
                                       :model model))))
        (let ((reply (json-parse-string (agent-tasks-spawn-from-file file)
                                        :object-type 'plist)))
          (should-not (plist-get reply :error))
          (should (equal (plist-get reply :model) model)))
        (should (equal started (list model)))
        (should (equal (plist-get (agent-tasks--task-to-plist
                                   (car (agent-tasks--load))) :model) model))
        (let ((reply (agent-tasks-spawn :name "default" :prompt "p" :cwd repo)))
          (should-not (plist-member reply :model)))
        (should-not (car started))))))

(ert-deftest agent-tasks-model-old-state-defaults-to-nil ()
  (should-not (agent-tasks-task-model
               (agent-tasks--task-from-plist '(:name "old")))))

(ert-deftest agent-tasks-model-error-reaches-json-caller ()
  (agent-tasks-test--with-spawn-env tmp
    (let ((repo (agent-tasks-test--make-repo tmp "r"))
          (file (expand-file-name "req.json" tmp)))
      (with-temp-file file
        (insert (json-serialize (list :name "bad" :prompt "p" :cwd repo
                                     :model "unknown/model"))))
      (cl-letf (((symbol-function 'agent-tasks--pilish-start)
                 (lambda (_dir &optional model)
                   (error "Unknown or unavailable pi model: %s" model))))
        (let ((reply (json-parse-string (agent-tasks-spawn-from-file file)
                                        :object-type 'plist)))
          (should (string-match-p "Unknown or unavailable pi model: unknown/model"
                                  (plist-get reply :error)))))
      (should-not (gethash "bad" agent-tasks--tasks))
      (should-not agent-tasks-test--sent))))

(ert-deftest agent-tasks-model-resume-forwards-persisted-pattern ()
  (agent-tasks-test--with-spawn-env tmp
    (let* ((file (expand-file-name "old.jsonl" tmp))
           (model "claude-bridge/claude-opus-5-5:high")
           (task (agent-tasks-test--register "old" tmp :chat-buffer nil
                                             :session-file file :model model))
           (calls nil))
      (with-temp-file file (insert "{}\n"))
      (cl-letf (((symbol-function 'agent-tasks--pilish-resume)
                 (lambda (file &optional model)
                   (push (list 'resume file model) calls)
                   (car (push (agent-tasks-test--fake-session tmp) fake-chats))))
                ((symbol-function 'agent-tasks--pilish-start)
                 (lambda (dir &optional model)
                   (push (list 'start dir model) calls)
                   (car (push (agent-tasks-test--fake-session dir) fake-chats)))))
        (agent-tasks--resume task)
        (should (equal (car calls) (list 'resume file model)))
        (delete-file file)
        (agent-tasks--resume task)
        (should (equal (car calls) (list 'start tmp model)))))))

(ert-deftest agent-tasks-model-dashboard-column ()
  (agent-tasks-test--with-status-env tmp
    (agent-tasks-test--register "pinned" tmp :repo tmp
                                :model "claude-bridge/claude-opus-5-5:high")
    (agent-tasks-test--register "default" tmp :repo tmp)
    (let ((chat (agent-tasks--pilish-start tmp)))
      (should (equal (nth 4 (agent-tasks-test--row (agent-tasks--entries) "pinned"))
                     "claude-bridge/claude-opus-5-5:high"))
      (should (equal (nth 4 (agent-tasks-test--row (agent-tasks--entries) "default"))
                     "default"))
      (should (equal (nth 4 (agent-tasks-test--row (agent-tasks--entries) chat)) "")))
    (with-temp-buffer
      (agent-tasks-list-mode)
      (should (equal (car (aref tabulated-list-format 4)) "Model")))))

(ert-deftest agent-tasks-model-completion-settings ()
  (agent-tasks-test--with-sandbox tmp
    (let ((process-environment (copy-sequence process-environment))
          (models '("claude-bridge/claude-opus-5-5" "openai-codex/gpt-6.1-sol")))
      (setenv "PI_CODING_AGENT_DIR" tmp)
      (should-not (agent-tasks--enabled-models))
      (with-temp-file (expand-file-name "settings.json" tmp)
        (insert (json-serialize (list :enabledModels (vconcat models)))))
      (should (equal (agent-tasks--enabled-models) models))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt candidates &rest _)
                   (should (equal candidates models))
                   "")))
        (should-not (agent-tasks--read-model)))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) "openai-codex/gpt-6.1-sol:high")))
        (should (equal (agent-tasks--read-model) "openai-codex/gpt-6.1-sol:high")))
      (with-temp-file (expand-file-name "settings.json" tmp) (insert "{"))
      (should (string-match-p "settings.json"
                              (agent-tasks-test--error-message
                               #'agent-tasks--enabled-models)))
      (setenv "PI_CODING_AGENT_DIR" nil)
      (setenv "HOME" tmp)
      (make-directory (expand-file-name ".pi/agent" tmp) t)
      (with-temp-file (expand-file-name ".pi/agent/settings.json" tmp)
        (insert (json-serialize (list :enabledModels (vconcat models)))))
      (should (equal (agent-tasks--enabled-models) models)))))

(ert-deftest agent-tasks-model-new-interactive-forwards-selection ()
  (let ((received nil))
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "text"))
              ((symbol-function 'agent-tasks--read-repo) (lambda () "/repo/"))
              ((symbol-function 'agent-tasks--read-model) (lambda () "opus:high"))
              ((symbol-function 'agent-tasks--refresh-dashboard) #'ignore)
              ((symbol-function 'agent-tasks-spawn)
               (lambda (&rest args)
                 (setq received args)
                 '(:worktree "/wt/" :base "main"))))
      (let ((current-prefix-arg nil)) (call-interactively #'agent-tasks-new))
      (should (equal (plist-get received :model) "opus:high")))))

;; Exercise the real adapter without loading or launching pilish.
(defvar pilish-extra-args nil)
(defmacro agent-tasks-test--with-pilish-primitives (&rest body)
  (declare (indent 0))
  `(let* ((pilish-extra-args '("--offline"))
          (chat (generate-new-buffer " *adapter-chat*"))
          (input (generate-new-buffer " *adapter-input*"))
          (argv nil) (history nil) (killed nil)
          (selected '(:provider "provider" :id "chosen"))
          (available [(:provider "provider" :id "chosen")])
          (failure nil))
     (with-current-buffer chat (setq-local pilish--process nil))
     (cl-letf (((symbol-function 'require)
                (lambda (feature &rest _)
                  (should (eq feature 'pilish)) t))
               ((symbol-function 'pilish--find-session) (lambda (&rest _) nil))
               ((symbol-function 'pilish--setup-session)
                (lambda (_dir) (setq argv pilish-extra-args) chat))
               ((symbol-function 'pilish--rpc-sync)
                (lambda (_proc command &optional _timeout)
                  (or failure
                      (list :success t :data
                            (if (equal (plist-get command :type) "get_state")
                                (list :model selected :sessionFile "/session.jsonl")
                              (list :models available))))))
               ((symbol-function 'pilish--apply-state-response)
                (lambda (buf response)
                  (with-current-buffer buf
                    (setq-local pilish--state (plist-get response :data)))))
               ((symbol-function 'pilish--session-file-cwd-or-error)
                (lambda (file) (file-name-directory file)))
               ((symbol-function 'pilish--load-session-history)
                (lambda (_proc _callback buf &rest _) (push buf history)))
               ((symbol-function 'agent-tasks--pilish-kill)
                (lambda (buf) (push buf killed)))
               ((symbol-function 'agent-tasks--pilish-input) (lambda (_) input)))
       (unwind-protect (progn ,@body)
         (kill-buffer chat)
         (kill-buffer input)))))

(ert-deftest agent-tasks-model-adapter-session-local-args ()
  (agent-tasks-test--with-pilish-primitives
    (should (eq (agent-tasks--pilish-start "/tmp/" "provider/chosen:high") chat))
    (should (equal argv '("--offline" "--model" "provider/chosen:high")))
    (should (equal pilish-extra-args '("--offline")))
    (should (equal (plist-get (buffer-local-value 'pilish--state chat) :model)
                   selected))
    (should-not killed)))

(ert-deftest agent-tasks-model-adapter-default-unchanged ()
  (agent-tasks-test--with-pilish-primitives
    (setq failure '(:success :false :error "must not validate default"))
    (should (eq (agent-tasks--pilish-start "/tmp/") chat))
    (should (equal argv '("--offline")))
    (should-not killed)))

(ert-deftest agent-tasks-model-adapter-rejects-custom-fallback ()
  (agent-tasks-test--with-pilish-primitives
    (setq selected '(:provider "provider" :id "typo"))
    (should (string-match-p "Unknown or unavailable pi model.*provider/typo"
                            (agent-tasks-test--error-message
                             (lambda ()
                               (agent-tasks--pilish-start "/tmp/" "provider/typo")))))
    (should (equal killed (list chat)))))

(ert-deftest agent-tasks-model-adapter-rpc-errors-and-timeouts ()
  (agent-tasks-test--with-pilish-primitives
    (setq failure '(:success :false :error "Model not found"))
    (should (string-match-p "provider/nope.*Model not found"
                            (agent-tasks-test--error-message
                             (lambda ()
                               (agent-tasks--pilish-start "/tmp/" "provider/nope")))))
    (cl-letf (((symbol-function 'pilish--rpc-sync) (lambda (&rest _) nil)))
      (should (string-match-p "provider/chosen.*timed out"
                              (agent-tasks-test--error-message
                               (lambda ()
                                 (agent-tasks--pilish-start "/tmp/" "provider/chosen"))))))
    (should (= (length killed) 2))))

(ert-deftest agent-tasks-model-adapter-refuses-to-reuse-live-session ()
  (agent-tasks-test--with-pilish-primitives
    (cl-letf (((symbol-function 'pilish--find-session) (lambda (&rest _) chat))
              ((symbol-function 'agent-tasks--pilish-process-live-p) (lambda (_) t)))
      (should (string-match-p "provider/chosen.*session already running"
                              (agent-tasks-test--error-message
                               (lambda ()
                                 (agent-tasks--pilish-start "/tmp/" "provider/chosen")))))
      (should-not argv)
      (should-not killed))))

(ert-deftest agent-tasks-model-adapter-rejects-blank-pattern ()
  (agent-tasks-test--with-pilish-primitives
    (should (string-match-p "Invalid pi model"
                            (agent-tasks-test--error-message
                             (lambda () (agent-tasks--pilish-start "/tmp/" "")))))
    (should-not argv)))

(ert-deftest agent-tasks-model-adapter-pinned-resume-uses-cli-not-switch ()
  (agent-tasks-test--with-pilish-primitives
    (agent-tasks-test--with-sandbox tmp
      (let ((file (expand-file-name "old.jsonl" tmp)))
        (with-temp-file file
          (insert (json-serialize (list :type "session" :cwd tmp)) "\n"))
        (should (eq (agent-tasks--pilish-resume file "provider/chosen:high") chat))
        (should (equal argv (list "--offline" "--session" file
                                  "--model" "provider/chosen:high")))
        (should (equal history (list chat)))
        (should (equal pilish-extra-args '("--offline")))))))

(provide 'agent-tasks-test)
;;; agent-tasks-test.el ends here
