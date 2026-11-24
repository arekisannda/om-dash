;;; om-dash-core.el --- om-dash: core settings, faces, utilities, block parameters -*- lexical-binding: t -*-

;; Copyright (C) 2024 Victor Gaydov and contributors

;;; License:

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Shared by all blocks: customization group, keywords and faces,
;; utilities, “OM_DASH“ drawer parameters, “OM_DASH_HEADING“ support,
;; templates, and commands to update blocks.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'let-alist)
(require 'org)
(require 'seq)
(require 's)
(require 'ts)

(defgroup om-dash nil
  "Building blocks for org-based dashboards."
  :prefix "om-dash-"
  :group 'org
  :link '(url-link "https://github.com/gavv/om-dash"))

(defcustom om-dash-todo-keywords nil
  "List of keywords considered as “todo“.

If block has any of the “todo“ keywords, block state is considered “todo“.
The first element from this list is used as block's heading keyword.

If a keyword from this list doesn't have a face in `om-dash-keyword-faces',
it uses standard face for `TODO' keyword.

When nil, filled automatically from `org-todo-keywords', `org-done-keywords',
and pre-defined keywords for github, imap, etc."
  :package-version '(om-dash . "0.1")
  :group 'om-dash
  :type '(choice (const :tag "Auto" nil)
                 (repeat string)))

(defcustom om-dash-done-keywords nil
  "List of keywords considered as “done“.

If block has only “done“ keywords, block state is considered “done“.
The first element from this list is used as block's heading keyword.

If a keyword from this list doesn't have a face in `om-dash-keyword-faces',
it uses standard face for `DONE' keyword.

When nil, filled automatically from `org-todo-keywords', `org-done-keywords',
and pre-defined keywords for github, imap, etc."
  :package-version '(om-dash . "0.1")
  :group 'om-dash
  :type '(choice (const :tag "Auto" nil)
                 (repeat string)))

(defcustom om-dash-keyword-faces
  '(
    ;; org-mode
    ("TODO" . om-dash-todo-keyword)
    ("DONE" . om-dash-done-keyword)
    ;; github
    ("OPEN" . om-dash-open-keyword)
    ("DRAFT" . om-dash-draft-keyword)
    ("MERGED" . om-dash-merged-keyword)
    ("CLOSED" . om-dash-closed-keyword)
    ;; imap
    ("NEW" . om-dash-new-keyword)
    ("UNREAD" . om-dash-unread-keyword)
    ("CLEAN" . om-dash-clean-keyword)
    ;;
    )
  "Assoc list to map keywords to faces.

If some keyword is not mapped to a face explicitly, default face is selected,
using face for TODO or DONE depending on whether that keyword is in
`om-dash-todo-keywords' or `om-dash-done-keywords'."
  :package-version '(om-dash . "0.1")
  :group 'om-dash
  :type '(alist :key-type (string :tag "Keyword")
                :value-type (symbol :tag "Face")))

(defcustom om-dash-tag-map nil
  "Assoc list to remap or unmap tag names.

Defines how tags are displayed in table.
You can map tag name to a different string or to nil to hide it."
  :package-version '(om-dash . "0.1")
  :group 'om-dash
  :type '(choice (const :tag "None" nil)
                 (alist :key-type (string :tag "Tag")
                        :value-type (choice (string :tag "Mapped Name")
                                            (const :tag "Hide" nil)))))

(defcustom om-dash-templates
  '(
    ;; OBSOLETE templates:
    (milestone . om-dash-github:milestone)
    (project-column . om-dash-github:project-column)
    ;;
    )
  "Assoc list of expandable templates for om-dash dynamic blocks.

Each entry is a cons of two symbols: template name and template function.

When you pass “:template foo“ as an argument to a dynamic block, it finds
a function in this list by key `foo' and uses it to “expand“ the template.

This function is invoked with dynamic block parameters plist and should
return a new plist.  The new plist is used to update the original
parameters by appending new values and overwriting existing values.

For example, if `org-dblock-write:om-dash-github' block has parameters:
  (:repo “owner/repo“
   :type `issue
   :template project-column
   :project 123
   :column “In progress“)

Dynamic block will use `project-column' as a key in `om-dash-templates'
and find `om-dash-github:project-column' function.

The function is invoked with the original parameter list, and returns
a modified parameter list:
  (:repo “owner/repo“
   :type `issue
   :open (“project:owner/repo/123“
          “.projectCards[] | (.column.name == \\“In progress\\“)“)
   :closed ““
   :headline “issues (owner/repo \\“1.2.3\\“)“)

Then modified parameters are interpreted by dynamic block as usual."
  :package-version '(om-dash . "0.1")
  :group 'om-dash
  :type '(alist :key-type (symbol :tag "Template Name")
                :value-type (function :tag "Template Function")))

(defcustom om-dash-verbose nil
  "Enable verbose logging.
If non-nil, all commands and queries are logged to `*om-dash*' buffer."
  :package-version '(om-dash . "0.1")
  :group 'om-dash
  :type 'boolean)

(defgroup om-dash-faces nil
  "Faces for om-dash mode."
  :group 'om-dash)

(defface om-dash-header-cell
  '((t (:inherit default)))
  "Face used for entire cell in om-dash table header.
You can use it so specify header background."
  :group 'om-dash-faces)

(defface om-dash-header-text
  '((t (:inherit org-table)))
  "Face used for text in om-dash table header.
You can use it so specify header font."
  :group 'om-dash-faces)

(defface om-dash-cell
  '((t (:inherit default)))
  "Face used for entire non-header cell in om-dash table.
You can use it so specify cell background."
  :group 'om-dash-faces)

(defface om-dash-text
  '((t (:inherit default)))
  "Face used for text in om-dash table non-header cell.
You can use it so specify cell font."
  :group 'om-dash-faces)

(defface om-dash-number
  '((t (:inherit org-link)))
  "Face used for issue or pull request numbers in om-dash tables."
  :group 'om-dash-faces)

(defface om-dash-username
  '((t (:inherit org-document-info)))
  "Face used for github usernames in om-dash tables."
  :group 'om-dash-faces)

(define-obsolete-face-alias
 'om-dash-author
 'om-dash-username "0.3")

(defface om-dash-todo-keyword
  '((t (:inherit org-todo :weight normal)))
  "Face used for `TODO' keyword in om-dash tables."
  :group 'om-dash-faces)

(defface om-dash-done-keyword
  '((t (:inherit org-done :weight normal)))
  "Face used for `DONE' keyword in om-dash tables."
  :group 'om-dash-faces)

(defface om-dash-open-keyword
  '((t (:inherit om-dash-todo-keyword)))
  "Face used for `OPEN' keyword in om-dash tables."
  :group 'om-dash-faces)

(defface om-dash-draft-keyword
  '((t (:inherit om-dash-todo-keyword :slant italic)))
  "Face used for `DRAFT' keyword (draft issues in v2 projects)."
  :group 'om-dash-faces)

(defface om-dash-merged-keyword
  '((t (:inherit om-dash-done-keyword)))
  "Face used for `MERGED' keyword in om-dash tables."
  :group 'om-dash-faces)

(defface om-dash-closed-keyword
  '((t (:inherit org-warning :weight normal)))
  "Face used for `CLOSED' keyword in om-dash tables."
  :group 'om-dash-faces)

(defface om-dash-new-keyword
  '((t (:inherit org-todo :weight normal)))
  "Face used for `NEW' keyword in om-dash tables."
  :group 'om-dash-faces)

(defface om-dash-unread-keyword
  '((t (:inherit org-todo :weight normal)))
  "Face used for `UNREAD' keyword in om-dash tables."
  :group 'om-dash-faces)

(defface om-dash-clean-keyword
  '((t (:inherit org-done :weight normal)))
  "Face used for `CLEAN' keyword in om-dash tables."
  :group 'om-dash-faces)

(defun om-dash--log (msg)
  "Log line to *om-dash* buffer."
  (if om-dash-verbose
      (with-current-buffer (get-buffer-create "*om-dash*")
        (goto-char (point-max))
        (insert ">>> ")
        (insert msg)
        (insert "\n"))))

(defun om-dash--plist-obsolete (plist key obsolete-key)
  "Get property by key or by deprecated key."
  (or (plist-get plist key)
      (when-let* ((value (plist-get plist obsolete-key)))
        (warn "om-dash: %S is deprecated, use %S instead."
              obsolete-key key)
        value)))

(defun om-dash--kwlistp (object)
  "Check if object is keyworded plist, like (:key1 val key2 val ...)."
  (and object
       (proper-list-p object)
       (> (length object) 0)
       (keywordp (car object))))

(defun om-dash--contains-p (list &rest elems)
  "Check if list has any of the elements."
  (seq-some (lambda (e)
              (seq-contains-p list e 'string=))
            elems))

(defun om-dash--join (separator &rest strings-or-lists)
  "Concatenate all strings and lists of strings into one flatten list.
Remove nils and empty strings.
Join resulting list into one string using a separator and return result."
  (when-let* ((seq
              (seq-remove
               's-blank-p
               (apply 'seq-concatenate 'list
                      (seq-map (lambda (elem)
                                 (if (listp elem)
                                     elem
                                   (list elem)))
                               strings-or-lists)))))
    (s-join separator seq)))

(defun om-dash--remove-nth (list n)
  "Return a copy of SEQUENCE with the element at index N removed."
  (seq-concatenate 'list
                   (seq-subseq list 0 n)
                   (seq-subseq list (1+ n))))

(defun om-dash--in-dblock-p ()
  "Check if point is inside dynamic block."
  (let ((case-fold-search t))
    (org-between-regexps-p "^[ \t]*#\\+BEGIN:"
                           "^[ \t]*#\\+END:"
                           (point-min)
                           (point-max))))

(defun om-dash--todo-keywords ()
  "Get list of TODO keywords."
  (unless om-dash-todo-keywords
    (setq-local om-dash-todo-keywords
                (seq-concatenate 'list
                                 ;; org
                                 (seq-difference org-todo-keywords-1
                                                 org-done-keywords)
                                 ;; github
                                 (list "OPEN"
                                       "DRAFT")
                                 ;; imap
                                 (list "NEW"
                                       "UNREAD"))))
  om-dash-todo-keywords)

(defun om-dash--done-keywords ()
  "Get list of DONE keywords."
  (unless om-dash-done-keywords
    (setq-local om-dash-done-keywords
                (seq-concatenate 'list
                                 ;; org
                                 org-done-keywords
                                 ;; github
                                 (list "MERGED"
                                       "CLOSED")
                                 ;; imap
                                 (list "CLEAN"))))
  om-dash-done-keywords)

(defun om-dash--choose-keyword (is-todo)
  "Select TODO/DONE keyword."
  (let ((todo-keywords (om-dash--todo-keywords))
        (done-keywords (om-dash--done-keywords)))
    (if is-todo
        (if todo-keywords
            (car todo-keywords)
          "TODO")
      (if done-keywords
          (car done-keywords)
        "DONE"))))

(defun om-dash--choose-face (keyword)
  "Select face for keyword."
  (let ((om-face (cdr (assoc keyword om-dash-keyword-faces)))
        (org-face (cdr (assoc keyword org-todo-keyword-faces))))
    (cond
     ;; face from om-dash-keyword-faces
     (om-face om-face)
     ;; face from org-todo-keyword-faces
     (org-face
      `(:inherit ,org-face :weight normal))
     ;; fallback to face for "TODO"
     ((and (seq-contains-p (om-dash--todo-keywords) keyword)
           (not (string= keyword "TODO")))
      (om-dash--choose-face "TODO"))
     ;; fallback to face for "DONE"
     ((and (seq-contains-p (om-dash--done-keywords) keyword)
           (not (string= keyword "DONE")))
      (om-dash--choose-face "DONE"))
     ;; give up
     (t 'default))))

(defun om-dash--face-spec (value)
  "Convert VALUE (face symbol or color string) into a face spec."
  (cond ((not value) nil)
        ((stringp value) `(:foreground ,value))
        (t value)))

(defun om-dash--choose-level ()
  "Select default outline level for a table."
  (save-excursion
    (while (om-dash--in-dblock-p)
      (org-previous-visible-heading 1))
    (1+ (org-outline-level))))

(defconst om-dash--heading-property "OM_DASH_HEADING"
  "Property that enables todo keyword updates of a heading.

When the heading containing an om-dash block has this property set
\(e.g. “:OM_DASH_HEADING: t“), updating the block sets todo keyword of
that heading to reflect the block's state: e.g. “TODO“ if there are
open topics, “DONE“ otherwise.  If the heading text also has a progress
marker “{/}“ or “{%}“, blocks that support it (e.g. `om-dash-github')
replace it with their progress, e.g. “{3/7}“ or “{43%}“.  Headings
without the property are never touched.")

(defun om-dash--heading-enabled-p ()
  "Check if heading at point has `om-dash--heading-property' enabled."
  (when-let* ((value (org-entry-get nil om-dash--heading-property)))
    (not (member (downcase (s-trim value)) '("" "nil" "no" "false")))))

(defun om-dash--set-heading-state (heading keyword)
  "Set todo KEYWORD of HEADING (position or marker).
Logging, blocking and state-change hooks are disabled, so that
regenerating a block doesn't add notes or fail on blocked tasks."
  (save-excursion
    (goto-char heading)
    (unless (member keyword org-todo-keywords-1)
      (user-error
       (s-concat "Om-dash: keyword %S is not a todo keyword in this buffer;"
                 " add it to org-todo-keywords or #+TODO line")
       keyword))
    (unless (equal (org-get-todo-state) keyword)
      (let ((org-inhibit-logging t)
            (org-log-done nil)
            (org-todo-log-states nil)
            (org-inhibit-blocking t)
            (org-blocker-hook nil)
            (org-trigger-hook nil)
            (org-after-todo-state-change-hook nil))
        (org-todo keyword)))))

(defconst om-dash--progress-regexp "{\\(?:[0-9]*/[0-9]*\\|[0-9]*%\\)}"
  "Regexp of progress marker in heading text: “{/}“, “{3/7}“, “{%}“, “{43%}“.
Curly braces are used because org recomputes its own “[/]“ cookies
from checkboxes and child headings, and would overwrite the value.")

(defun om-dash--heading-progress-p ()
  "Check if the heading containing the current block shows progress.
True if the heading has “:OM_DASH_HEADING: t“ property and a progress
marker (see `om-dash--progress-regexp') in its text."
  (save-excursion
    (and (ignore-errors (org-back-to-heading t) t)
         (om-dash--heading-enabled-p)
         (re-search-forward om-dash--progress-regexp (line-end-position) t)
         t)))

(defun om-dash--update-heading-progress (done total)
  "Set progress marker of the heading containing the current block.
DONE and TOTAL are numbers of done and all items of the block.  The
marker is replaced with “{DONE/TOTAL}“ or, if it's a percentage marker,
“{PERCENT%}“.  Nothing is done if the heading has no marker or no
“:OM_DASH_HEADING: t“ property (see `om-dash--heading-property')."
  (save-excursion
    (when (and (ignore-errors (org-back-to-heading t) t)
               (om-dash--heading-enabled-p)
               (re-search-forward om-dash--progress-regexp (line-end-position) t))
      (let ((new (if (string-suffix-p "%}" (match-string 0))
                     (format "{%d%%}" (if (> total 0) (round (* 100.0 done) total) 0))
                   (format "{%d/%d}" done total))))
        (unless (equal new (match-string 0))
          (replace-match new t t))))))

(defun om-dash--insert-heading (keyword _headline _level)
  "Update todo keyword of the heading containing the current block.

The heading is updated only if it has “:OM_DASH_HEADING: t“ property
\(see `om-dash--heading-property'); otherwise nothing is done.  Om-dash
never inserts or renames headings, and nothing is inserted into the
block itself, so the block stays a valid dynamic block and doesn't
affect the outline.

If block generates several tables, the heading gets “todo“ keyword if
any table is “todo“, otherwise keyword of the first table."
  (save-excursion
    (when (and (ignore-errors (org-back-to-heading t) t)
               (om-dash--heading-enabled-p))
      (setq om-dash--dblock-keywords
            (append om-dash--dblock-keywords (list keyword)))
      (om-dash--set-heading-state
       (point)
       (or (seq-find (lambda (kw)
                       (member kw (om-dash--todo-keywords)))
                     om-dash--dblock-keywords)
           (car om-dash--dblock-keywords))))))

(defun om-dash--shell-quote (arg)
  "Quote argument for shell."
  (let ((str (format "%s" arg)))
    ;; minimize quoting for more readable logs
    (cond ((s-matches-p "^[a-zA-Z0-9/:.,_-]+$" str)
           str)
          ((and (not (s-contains-p "'" str))
                (eq system-type 'gnu/linux))
           (format "'%s'" str))
          (t
           (shell-quote-argument str)))))

(defun om-dash--shell-run (command capture)
  "Run shell command."
  (om-dash--log command)
  (with-output-to-string
    (let ((status
           (call-process-shell-command command nil
                                       (if capture
                                           standard-output
                                         nil))))
      (unless (eq status 0)
        (om-dash--log (format "command exited with status %s" status))
        (error "Om-dash: command failed")))))

(defun om-dash--parse-reltime (str)
  "Parse relative timestamp like -123d."
  (when (string-match "^-\\([[:digit:]]+\\)\\([a-z][a-z]?\\)$" str)
    (let ((count (string-to-number (match-string 1 str)))
          (unit (match-string 2 str)))
      (ts-format "%Y-%m-%d"
                 (cond
                  ;; "-123d"
                  ((string= unit "d")
                   (ts-adjust 'day (- count) (ts-now)))
                  ;; "-123w"
                  ((string= unit "w")
                   (ts-adjust 'day (- (* count 7)) (ts-now)))
                  ;; "-123mo"
                  ((string= unit "mo")
                   (ts-adjust 'month (- count) (ts-now)))
                  ;; "-123y"
                  ((string= unit "y")
                   (ts-adjust 'year (- count) (ts-now)))
                  (t
                   (user-error "Om-dash: bad timestamp %S" str)))))))

(defun om-dash--expand-template (params)
  "Return params with expanded :template (if it's present)."
  (let ((result-params
         (if-let* ((template-name (plist-get params :template)))
             (let* ((template (or (assoc template-name om-dash-templates)
                                  (user-error "Om-dash: unknown :template %s"
                                              template-name)))
                    (expanded-params (funcall (cdr template) params))
                    (merged-params (seq-copy params)))
               (while expanded-params
                 (let ((key (car expanded-params))
                       (val (cadr expanded-params)))
                   (setq merged-params (plist-put merged-params key val))
                   (setq expanded-params (cddr expanded-params))))
               merged-params)
           (seq-copy params))))
    (if (plist-member result-params :template)
        (cl-remf result-params :template))
    result-params))

(defun om-dash--read-plist (str)
  "Read property value STR as a plist, e.g. “:owner \"foo\" :project 7“.
Returns nil if STR is nil or blank."
  (when (and str (s-present-p str))
    (let ((plist (condition-case err
                     (read (concat "(" str ")"))
                   (error
                    (user-error "Om-dash: can't parse property value %S: %s"
                                str (error-message-string err))))))
      (unless (om-dash--kwlistp plist)
        (user-error "Om-dash: property value must be a plist: %S" str))
      plist)))

(defun om-dash--plist-merge (plists)
  "Merge list of PLISTS into one; values from later plists win."
  (let (result)
    (dolist (plist plists)
      (while plist
        (setq result (plist-put result (car plist) (cadr plist)))
        (setq plist (cddr plist))))
    result))

(defun om-dash--block-property (block-name)
  "Name of the type-specific property for BLOCK-NAME.
E.g. “om-dash-github“ -> “OM_DASH_GITHUB“."
  (upcase (replace-regexp-in-string "-" "_" (format "%s" block-name))))

(defun om-dash--drawer-params (block-name)
  "Collect block parameters from property drawers of headings around point.

Reads “OM_DASH“ (common for all blocks) and “OM_DASH_<TYPE>“ (e.g.
“OM_DASH_GITHUB“ for BLOCK-NAME “om-dash-github“) properties from the
heading containing point and from all its ancestors.  Values are merged
from outermost to innermost heading, so nearer headings override outer
ones; on the same heading, “OM_DASH_<TYPE>“ overrides “OM_DASH“.
Continuation properties like “OM_DASH_GITHUB+“ are supported."
  (let ((type-prop (om-dash--block-property block-name))
        levels)
    (save-excursion
      (when (ignore-errors (org-back-to-heading t) t)
        (let ((continue t))
          (while continue
            (push (append (om-dash--read-plist (org-entry-get nil "OM_DASH"))
                          (om-dash--read-plist (org-entry-get nil type-prop)))
                  levels)
            (setq continue (org-up-heading-safe))))))
    ;; levels is now ordered from outermost to innermost
    (om-dash--plist-merge levels)))

(defun om-dash--merge-drawer-params (block-name params)
  "Return PARAMS of block BLOCK-NAME merged on top of drawer parameters."
  (om-dash--plist-merge (list (om-dash--drawer-params block-name)
                              params)))

(defvar om-dash--dblock-keywords nil
  "Keywords chosen for tables of the block being generated.
Used to compute keyword of the block's heading (see `om-dash--insert-heading').")

(defun om-dash--prepare-params (params)
  "Merge drawer config, expand template in PARAMS, apply common parameters.

Parameters from “OM_DASH“ and “OM_DASH_<TYPE>“ properties of enclosing
headings (see `om-dash--drawer-params') are used as defaults, and
parameters given inline on the “#+BEGIN:“ line override them.
Then `:template' is expanded.  Returns resulting params."
  (let* ((name (plist-get params :name))
         (params (if name
                     (om-dash--merge-drawer-params name params)
                   params))
         (params (om-dash--expand-template params)))
    (setq om-dash--dblock-keywords nil)
    params))

(defun om-dash--row-link ()
  "Return target of the first org link on the current line, or nil."
  (save-excursion
    (beginning-of-line)
    (when (re-search-forward org-link-bracket-re (line-end-position) t)
      (match-string-no-properties 1))))

(defun om-dash--dblock-params (name)
  "Return inline parameters of the enclosing dynamic block NAME, or nil.
The result always contains `:name', so it's non-nil inside the block
even if the “#+BEGIN:“ line has no parameters.
Point must be inside the block."
  (save-excursion
    (let ((case-fold-search t)
          (start (point)))
      (when (and (re-search-backward
                  (format "^[ \t]*#\\+BEGIN:[ \t]+%s\\(.*\\)$" (regexp-quote name))
                  nil t)
                 ;; make sure the block wasn't closed before start point
                 (not (save-excursion
                        (re-search-forward "^[ \t]*#\\+END:" start t))))
        (append (list :name name)
                (read (concat "(" (match-string-no-properties 1) ")")))))))

(defun om-dash--dblock-name ()
  "Return name of the enclosing om-dash dynamic block, or nil.
E.g. “om-dash-github“ for “#+BEGIN: om-dash-github ...“.
Point must be inside the block."
  (save-excursion
    (let ((case-fold-search t)
          (start (point)))
      (when (and (re-search-backward
                  "^[ \t]*#\\+BEGIN:[ \t]+\\(om-dash-[^ \t\n]+\\)" nil t)
                 ;; make sure the block wasn't closed before start point
                 (not (save-excursion
                        (re-search-forward "^[ \t]*#\\+END:" start t))))
        (match-string-no-properties 1)))))

(defun om-dash--block-params (name)
  "Return effective parameters of the enclosing dynamic block NAME, or nil.
Same as what the block itself uses: drawer parameters of enclosing
headings, overridden by inline “#+BEGIN:“ parameters, with expanded
template.  Point must be inside the block."
  (when-let* ((inline (om-dash--dblock-params name)))
    (om-dash--expand-template
     (om-dash--merge-drawer-params name inline))))

;;;###autoload
(defun om-dash-update-tree ()
  "Update all dynamic blocks in current tree, starting from top-level entry.

E.g., for the following document:

  * 1.               ---o
  ** 1.1    <- cursor   |
  *** 1.1.1             | [tree]
  *** 1.1.2             |
  ** 1.2             ---o
  * 2.
  ** 2.1

the function updates all blocks inside 1., 1.1, 1.1.1, 1.1.2, 1.2."
  (interactive)
  (save-excursion
    (while (org-up-heading-safe))
    (om-dash-update-subtree)))

;;;###autoload
(defun om-dash-update-subtree ()
  "Update all dynamic blocks in current subtree, starting from current entry.

E.g., for the following document:

  * 1.
  ** 1.1    <- cursor --o
  *** 1.1.1             | [subtree]
  *** 1.1.2           --o
  ** 1.2
  * 2.
  ** 2.1

the function updates all blocks inside 1.1, 1.1.1, 1.1.2."
  (interactive)
  (save-excursion
    (outline-back-to-heading)
    (let* ((start-level (org-current-level))
           (_start-point (point-marker))
           (end-point (save-excursion
                        (outline-next-heading)
                        (while (and (not (eobp))
                                    (> (org-current-level) start-level))
                          (outline-next-heading))
                        (point-marker)))
           (num-blocks 0))
      (while (and (re-search-forward "^[ \t]*#\\+BEGIN:" nil t)
                  (< (point) end-point))
        (when (om-dash--in-dblock-p)
          (save-excursion
            (org-dblock-update))
          (setq num-blocks (1+ num-blocks))))
      (message "Updated %s dynamic block(s)." num-blocks))))

(provide 'om-dash-core)
;;; om-dash-core.el ends here
