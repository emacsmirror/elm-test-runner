;;; elm-test-el.el --- Enhanced support for running elm-test

;; Copyright (C) 2017  Juan Edi

;; Author: Juan Edi
;; Keywords: elm elm-test
;; Version: 0.0.1

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;;; Commentary:

;; At least for the moment, this package just sets up a few fuctions to run elm
;; tests from inside emacs when using elm-mode.
;;
;; Most of it is just a copy of the fantastic rspec-mode
;; (https://github.com/pezra/rspec-mode)

;;; Code:

(require 'compile)
(require 'ansi-color)

(defgroup elm-test nil
  "elm-test integration"
  :group 'languages)

(defcustom elm-test-command nil
  "Use to explicitly set the command that will be used to run elm-test. If nil,
will try to use a locally installed node runner and fallback to a globally
installed 'elm-test' executable"
  :type 'string
  :group 'elm-test)

(defcustom elm-test-command-options nil
  "Default options used with elm-test-command."
  :type 'string
  :group 'elm-test)

(defcustom elm-test-preferred-test-suffix "Test"
  "Preferred suffix for test files. Useful if, for example, you prefer the tests
for module 'Foo' to live in 'FooSpecs' instead of 'FooTest'."
  :type 'string
  :group 'elm-test)

(defvar elm-test-run-directory-for-file 'elm-test--standard-project-root-for-file)
(defvar elm-test-project-root-for-file 'elm-test--standard-project-root-for-file)
(defvar elm-test-template-for-module 'elm-test--default-template-for-module)

(define-compilation-mode elm-test-compilation-mode "Elm Test Compilation"
  "Compilation mode for elm-test output."
  (add-hook 'compilation-filter-hook 'elm-test--colorize-compilation-buffer nil t)
  )

(defun elm-test-run ()
  "Run elm-test on the current buffer's file."
  (interactive)
  (elm-test--run-target
   (buffer-file-name)
   elm-test-command-options))

(defun elm-test-run-project ()
  (interactive)
  (elm-test--run-target
   (elm-test--test-directory (buffer-file-name))
   elm-test-command-options))

(defun elm-test-run-directory ()
  (interactive)
  (let ((selected-dir (elm-test--prompt-directory)))
    (if selected-dir
        (elm-test--run-target
         selected-dir
         elm-test-command-options))))

(defun elm-test-watch ()
  "Run elm-test on the current buffer's file in watch mode."
  (interactive)
  (elm-test--run-target
   (buffer-file-name)
   (concat elm-test-command-options " --watch")))

(defun elm-test-rerun ()
  "Re-run the last elm-test invocation."
  (interactive)
  (if (not elm-test--last-directory)
      (error "No previous verification")
    (let ((default-directory elm-test--last-directory))
      (apply #'elm-test--compile elm-test--last-arguments))))

(defun elm-test-toggle-test-and-target ()
  "Switch to the test or the target file for the current buffer.
If the current buffer is visiting a test file, switches to the
target, otherwise the test."
  (interactive)
  (if (elm-test--buffer-is-test-p)
      (elm-test--go-to-matching-target-file (buffer-file-name))
    (elm-test--go-to-matching-test-file (buffer-file-name))))

(defun elm-test--go-to-matching-target-file (file-name)
  (let ((matching-target-file (elm-test--target-file-for file-name)))
    (if matching-target-file
        (find-file matching-target-file)
        (message "Could not find matching target file."))))

(defun elm-test--go-to-matching-test-file (file-name)
  (let* ((matching-test-file (elm-test--test-file-for file-name))
         (test-directory (elm-test--test-directory file-name))
         (matching-test-file-exists
          (or
           (file-exists-p matching-test-file)
           (elm-test--offer-create-test-file matching-test-file test-directory))))
    (if matching-test-file-exists
        (find-file matching-test-file)
      (message "Could not find matching target file. Maybe the test directory is not readable?"))))

(defun elm-test--offer-create-test-file (file-name test-directory)
  (when (y-or-n-p (concat "File " matching-test-file " does not exist. Create it?"))
    (when (not (file-readable-p (file-name-directory file-name)))
      (make-directory (file-name-directory file-name) t))
    (write-region
     (apply elm-test-template-for-module (list (elm-test--test-module-name file-name test-directory)))
     nil file-name)
    file-name))

(defun elm-test--test-module-name (file-name test-directory)
  "Builds the name of the elm module for a test file"
  (replace-regexp-in-string
   "/" "."
   (replace-regexp-in-string
    "\.elm$" ""
    (file-relative-name file-name test-directory))))

(defun elm-test--default-template-for-module (test-module-name)
  (concat
   "module " test-module-name " exposing (tests)\n"
   "\n"
   "import Expect\n"
   "import Test exposing (..)\n"
   "\n"
   "\n"
   "tests : Test\n"
   "tests = test \"something obvious\" <|\n"
   "       \\() ->\n"
   "           Expect.equal 1 1"))

;;;###autoload
(defun elm-test--buffer-is-test-p ()
  "Return true if the current buffer is a test."
  (and (buffer-file-name)
       (elm--test-test-file-p (buffer-file-name))))

(defun elm--test-test-file-p (a-file-name)
  "Return true if the specified A-FILE-NAME is a test."
  (numberp (string-match
            (concat elm-test-preferred-test-suffix "\\.elm\\'")
            a-file-name)))

(defun elm-test--test-file-for (a-file-name)
  "Find test for the specified file."
  (if (elm--test-test-file-p a-file-name)
      a-file-name
    ;; This replace-regex accounts for target-files living in "holder"
    ;; directories such as "src" (since we don't want that part to appear in the
    ;; expected test file name).
    (let ((replace-regex (if (elm-test--target-in-holder-dir-p a-file-name)
                             "^\\.\\./[^/]+/"
                           "^\\.\\./"))
          (relative-file-name (file-relative-name a-file-name (elm-test--test-directory a-file-name))))
      (elm-test--testize-file-name (expand-file-name (replace-regexp-in-string replace-regex "" relative-file-name)
                                                 (elm-test--test-directory a-file-name))))))

(defun elm-test--target-in-holder-dir-p (a-file-name)
  ;; tells if A-FILE-NAME is contained in one of the "well known" source
  ;; directories (that would be only "./src" for the moment)
  (string-match (concat "^" (concat
                             (regexp-quote (elm-test--project-root a-file-name))
                             "src"
                             "/"))
                a-file-name))

(defun elm-test--target-file-for (a-spec-file-name)
  "Find the target for A-SPEC-FILE-NAME."
  (let ((candidate (elm-test--targetize-file-name a-spec-file-name)))
    (cl-loop for dir in (list "." "src")
             for target = (replace-regexp-in-string
                           "/tests/"
                           (concat "/" dir "/")
                           candidate)
             if (file-exists-p target)
             return target)))

(defun elm-test--parent-directory (a-directory)
  "Returns the directory of which A-DIRECTORY is a child"
  (file-name-directory (directory-file-name a-directory)))

(defun elm-test--root-directory-p (a-directory)
  "Return t if A-DIRECTORY is the root."
  (equal a-directory (elm-test--parent-directory a-directory)))

(defun elm-test--test-directory (a-file)
  "Return the nearest test directory that could contain tests for A-FILE."
  (if (file-directory-p a-file)
      (or
       (car (directory-files a-file t "^tests$"))
       (if (elm-test--root-directory-p a-file)
           nil
         (elm-test--test-directory (elm-test--parent-directory a-file))))
    (elm-test--test-directory (elm-test--parent-directory a-file))))

(defun elm-test--testize-file-name (a-file-name)
  "Return A-FILE-NAME but converted in to a test file name."
  (concat
   (file-name-directory a-file-name)
   (replace-regexp-in-string
    "\\.elm$"
    (concat elm-test-preferred-test-suffix ".elm")
    (file-name-nondirectory a-file-name))))

(defun elm-test--targetize-file-name (a-file-name)
  "Return A-FILE-NAME but converted into a non-test file name with EXTENSION."
  (concat (file-name-directory a-file-name)
          (elm-test--file-name-with-extension
           (replace-regexp-in-string
            (concat elm-test-preferred-test-suffix "\\.elm")
            ".elm"
            (file-name-nondirectory a-file-name)))))

(defun elm-test--file-name-with-extension (a-file-name)
  "Add .elm file extension to A-FILE-NAME if it does not already have an extension."
  (if (file-name-extension a-file-name)
      a-file-name ;; file has a extension already so do nothing
    (concat a-file-name ".elm")))

(defun elm-test--run-target (test-file &rest opts)
  "Run elm-test on SPEC_FILE with the specified options OPTS."
  (elm-test--compile (shell-quote-argument test-file) opts))

(defun elm-test--compile (target &optional opts)
  "Run a compile for TARGET with the specified options OPTS."

  (setq elm-test--last-directory default-directory
        elm-test--last-arguments (list target opts))

  (let ((default-directory (or (elm-test--run-directory)
                               (elm-test--standard-project-root-for-file (buffer-file-name))
                               default-directory))
        ; unset TERM=dumb to allow colorized output
        (compilation-environment '("TERM=ansi")))
    (compile
     (elm-test--compile-command target opts)
     'elm-test-compilation-mode)))

(defun elm-test--colorize-compilation-buffer ()
  (toggle-read-only)
  (ansi-color-apply-on-region compilation-filter-start (point))
  (toggle-read-only))

(defun elm-test--run-directory (&optional current-file-name)
  (let*
      ((starting-point (or current-file-name (buffer-file-name)))
       (root-dir (apply elm-test-run-directory-for-file (list starting-point))))
    (expand-file-name root-dir)))

(defun elm-test--prompt-directory ()
  (let ((selected-dir (read-directory-name "Test directory: " (file-name-directory buffer-file-name) nil t)))
    (when (and selected-dir (not (eq selected-dir "")))
      (expand-file-name selected-dir))))

(defun elm-test--project-root (&optional current-file-name)
  (let*
      ((starting-point (or current-file-name (buffer-file-name)))
       (root-dir (apply elm-test-project-root-for-file (list starting-point))))
    (expand-file-name root-dir)))

(defun elm-test--standard-project-root-for-file (current-file-name)
  "Looks for the root of an elm project. That is, the one with the main elm-package.json
This assumes a directory structure in which the root contains a 'tests' directory
for elm-test stuff."
  ;; If we are on a target file, return the first directory we see with an elm-package.json
  ;; If we are on a test file, it's the one above.
  (let*
      ((first-elm-package-dir (locate-dominating-file current-file-name "elm-package.json"))
       (parent-dir (elm-test--parent-directory first-elm-package-dir))
       (parent-dir-elm-package (car (directory-files parent-dir t "^elm-package\.json$"))))

    (if parent-dir-elm-package
        parent-dir
        first-elm-package-dir)))

(defun elm-test--compile-command (target &optional opts)
  "Composes elm-test command line for the compile function"
  (mapconcat 'identity `(,(elm-test--runner)
                         ,(elm-test--runner-options opts)
                         ,target) " "))

(defun elm-test--runner ()
  (or elm-test-command (elm-test--detect-node-runner)))

(defun elm-test--detect-node-runner ()
  (let ((local-runner-path (concat default-directory "node_modules/.bin/elm-test")))
    (if (file-readable-p local-runner-path)
        local-runner-path
      "elm-test")))

(defun elm-test--runner-options (&optional opts)
  "Return string of options from OPTS for command line."
  (let ((opts (if (listp opts)
                  opts
                (list opts))))
    (mapconcat 'identity opts " ")))

(provide 'elm-test-el)
;;; elm-test.el ends here
