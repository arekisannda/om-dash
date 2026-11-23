;;; om-dash.el --- Building blocks for org-based dashboards -*- lexical-binding: t -*-

;; Copyright (C) 2024 Victor Gaydov and contributors

;; Author: Victor Gaydov <victor@enise.org>
;; Created: 22 May 2024
;; URL: https://github.com/gavv/om-dash
;; Version: 0.6
;; Package-Requires: ((emacs "28.2") (org-ql "0.8.10") (s "1.13.0") (ts "0.3"))
;; Keywords: org, outlines

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

;; `om-dash' implements a set of dynamic blocks for org-mode that you can use
;; to compose a custom dashboard for your projects.

;; The following dynamic blocks are available:
;; * `om-dash-github'
;;   generates a table with issues or pull requests from github repository
;; * `om-dash-orgfile'
;;   generates tables with top-level entries from an org file
;; * `om-dash-imap'
;;   generates table with unread email counters for IMAP folder
;; * `om-dash-command'
;;   generates a table from JSON or CSV output of a shell command
;; * `om-dash-function'
;;   generates a table from output of a Elisp function

;; The package also provides a minor mode `om-dash-mode' that applies
;; highlighting to the generated tables.

;; Command `om-dash-github-set-project-status' changes v2 project status
;; (e.g. Todo / In Progress) of the issue or pull request at point.
;; Commands `om-dash-github-close-topic', `om-dash-github-reopen-topic',
;; and `om-dash-github-toggle-topic-state' close or reopen it.
;; Commands `om-dash-github-create-issue' and `om-dash-github-create-draft'
;; create a topic from a new row typed into the table.
;; Commands `om-dash-github-edit-body', `om-dash-github-edit-labels', and
;; `om-dash-github-edit-assignees' edit the topic on the current row.

;; Block parameters can be given inline on the “#+BEGIN:“ line, or in
;; property drawers of enclosing headings, which allows to share common
;; configuration between blocks:
;;
;;   * Infra dashboard
;;   :PROPERTIES:
;;   :OM_DASH_GITHUB:  :owner "octocat" :project 7 :group-by :repo
;;   :END:
;;   ** TODO Pull requests
;;   :PROPERTIES:
;;   :OM_DASH_HEADING: t
;;   :END:
;;   #+BEGIN: om-dash-github :type pullreq
;;   #+END:
;;   ** TODO Issues
;;   :PROPERTIES:
;;   :OM_DASH_HEADING: t
;;   :END:
;;   #+BEGIN: om-dash-github :type issue :closed "-1w"
;;   #+END:
;;
;; To make a block update todo keyword of its heading (e.g. TODO if there
;; are open topics, DONE otherwise), set “:OM_DASH_HEADING: t“ property
;; on that heading.  Om-dash never inserts or renames headings.
;;
;; Colors of project statuses in `om-dash-mode' are declared with
;; “OM_DASH_STATUS_FACES“ property (inherited, can be set file-wide with
;; “#+PROPERTY:“), e.g.:
;;
;;   #+PROPERTY: OM_DASH_STATUS_FACES "Todo" "gray60" "In Progress" warning "Done" success
;;
;; “OM_DASH“ applies to all blocks, “OM_DASH_<TYPE>“ (e.g. “OM_DASH_GITHUB“,
;; “OM_DASH_ORGFILE“, “OM_DASH_IMAP“) applies to blocks of that type.
;; Values from nearer headings override outer ones, and inline parameters
;; override all of them.  Long values can be split using “OM_DASH_GITHUB+“.

;; In addition, there is support for templates, which allow to create
;; reusable parameterized configurations of the above blocks.

;; Refer to README.org for examples and screenshots.

;;; Quoting:

;; A brief note on docstring quoting styles in this package:

;;  1. Symbols, functions, and variables are quoted in standard way `like-this'.

;;  2. Since double quotes are used very often in docstrings, we use unicode
;;     quotes “like this“ instead double quotes "like this" to avoid backslash hell.

;;  3. In tables inside docstrings, we use apostrophes 'like-this' instead of
;;     standard quotes `like-this' to prevent quote translation; otherwise, table
;;     alignment would be broken in the help buffer.

;;; Code:

(require 'auth-source)
(require 'cl-lib)
(require 'imap)
(require 'json)
(require 'let-alist)
(require 'org)
(require 'seq)

(require 'org-ql)
(require 's)
(require 'ts)

;; https://github.com/mrc/el-csv
(require 'parse-csv nil 'noerror)

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

(defcustom om-dash-status-faces nil
  "Default assoc list to map project status names to faces.

Keys are status names as shown in the :project-status column, e.g.
“In Progress“ (matched exactly, case-sensitive, so that
status “Done“ doesn't affect keyword “DONE“).  Values are either a face
symbol or a color string (used as foreground), e.g.:

  ((“Todo“ . “gray60“)
   (“In Progress“ . warning)
   (“Done“ . success))

Faces can also be declared in the org file using “OM_DASH_STATUS_FACES“
property (see `om-dash--status-faces-property'), which takes precedence
over this variable."
  :package-version '(om-dash . "0.7")
  :group 'om-dash
  :type '(alist :key-type (string :tag "Status")
                :value-type (choice (face :tag "Face")
                                    (color :tag "Foreground Color"))))

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

(define-obsolete-variable-alias
  'om-dash-table-width
  'om-dash-table-fixed-width "0.2")

(define-obsolete-variable-alias
  'om-dash-squeeze-empty-columns
  'om-dash-table-squeeze-empty "0.2")

(define-obsolete-variable-alias
  'om-dash-link-style
  'om-dash-table-link-style "0.2")

(defcustom om-dash-table-fixed-width nil
  "If non-nil, align tables to have given fixed width.
If nil, tables have minimum width that fits their contents."
  :package-version '(om-dash . "0.2")
  :group 'om-dash
  :type '(choice (const :tag "Minimum Width" nil)
                 (integer :tag "Fixed Width")))

(defcustom om-dash-table-squeeze-empty t
  "If non-nil, automatically remove empty columns from tables.
E.g. if every row has empty tags, :tags column is removed from this table."
  :package-version '(om-dash . "0.2")
  :group 'om-dash
  :type 'boolean)

(defcustom om-dash-table-link-style :cell
  "How links are generated in om-dash tables.

Allowed values:
 - `:none' - no links are inserted
 - `:text' - only cell text becomes a link
 - `:cell' - whole cell becomes a link"
  :package-version '(om-dash . "0.2")
  :group 'om-dash
  :type '(choice (const :tag "No links" :none)
                 (const :tag "Cell Text Is Link" :text)
                 (const :tag "Whole Cell Is Link" :cell)))

(defcustom om-dash-table-time-format "%a, %d %b %Y"
  "Format for `format-time-string' used for times in tables.
E.g. used for github columns like :created-at, :updated-at, etc."
  :package-version '(om-dash . "0.3")
  :group 'om-dash
  :type 'string)

(defcustom om-dash-github-columns
  '(:state
    :number
    :author
    :title-link)
  "Column list for `om-dash-github' tables.

Supported values:

| symbol                  | example           |
|-------------------------+-------------------|
| :state                  | OPEN, CLOSED, ... |
| :number                 | #123              |
| :repo                   | owner/repo        |
| :parent                 | #12               |
| :sub-issues             | 2/5               |
| :title                  | text              |
| :title-link             | [[link][text]]    |
| :milestone              | 1.2.3             |
| :tags                   | :tag1:tag2:...:   |
| :author                 | @octocat          |
| :assignee               | @octocat,@github  |
| :reviewer               | @octocat,@github  |
| :project                | text              |
| :project-status         | text              |
| :classic-project        | text              |
| :classic-project-status | text              |
| :created-at             | date              |
| :updated-at             | date              |
| :closed-at              | date              |
| :merged-at              | date              |"
  :package-version '(om-dash . "0.1")
  :group 'om-dash
  :type '(repeat symbol))

(defcustom om-dash-orgfile-columns
  '(:state
    :title-link)
  "Column list for `om-dash-orgfile' tables.

Supported values:

| symbol      | example         |
|-------------+-----------------|
| :state      | TODO, DONE, ... |
| :title      | text            |
| :title-link | [[link][text]]  |
| :tags       | :tag1:tag2:...: |"
  :package-version '(om-dash . "0.1")
  :group 'om-dash
  :type '(repeat symbol))

(defcustom om-dash-imap-columns
  '(:state
    :new
    :unread
    :total
    :folder)
  "Column list for `om-dash-imap' tables.

Supported values:

| symbol      | example            |
|-------------+--------------------|
| :state      | NEW, UNREAD, CLEAN |
| :new        | 10                 |
| :unread     | 20                 |
| :total      | 30                 |
| :folder     | foo/bar            |"
  :package-version '(om-dash . "0.3")
  :group 'om-dash
  :type '(repeat symbol))

(defcustom om-dash-github-limit 200
  "Default limit for github queries.

E.g. if you query “all open issues“ or “closed issues since january“,
only last `om-dash-github-limit' results are returned."
  :package-version '(om-dash . "0.1")
  :group 'om-dash
  :type 'integer)

(defcustom om-dash-github-fields
  '((pullreq
     .
     ("assignees"
      "author"
      "autoMergeRequest"
      "baseRefName"
      "body"
      "closed"
      "closedAt"
      "createdAt"
      "headRefName"
      "headRefOid"
      "headRepository"
      "headRepositoryOwner"
      "id"
      "isCrossRepository"
      "isDraft"
      "labels"
      "maintainerCanModify"
      "mergeable"
      "mergeCommit"
      "mergedAt"
      "mergedBy"
      "mergeStateStatus"
      "milestone"
      "number"
      "potentialMergeCommit"
      "state"
      "title"
      "updatedAt"
      "url"))
    (issue
     .
     ("assignees"
      "author"
      "closed"
      "closedAt"
      "createdAt"
      "id"
      "labels"
      "milestone"
      "number"
      "state"
      "title"
      "updatedAt"
      "url")))
  "List of json fields enabled by default in github queries.

This defines which fields are present in github responses and hence can
be used in jq selectors.

We don't enable all fields by default because some of them noticeably
slow down response times.

There is also `om-dash-github-auto-enabled-fields', which defines fields
that are enabled automatically for a query if jq selector contains them.

In addition, `org-dblock-write:om-dash-github' accept `:fields'
parameter, which can be used to overwrite fields list per-block."
  :package-version '(om-dash . "0.1")
  :group 'om-dash
  :type '(alist :key-type (choice (const :tag "Pull Request" pullreq)
                                  (const :tag "Issue" issue))
                :value-type (repeat :tag "Field" string)))

(defcustom om-dash-github-auto-enabled-fields
  '((pullreq
     .
     ("additions"
      "changedFiles"
      "comments"
      "commits"
      "deletions"
      "files"
      "latestReviews"
      "projectCards"
      "projectItems"
      "reactionGroups"
      "reviewDecision"
      "reviewRequests"
      "reviews"
      "statusCheckRollup"))
    (issue
     .
     ("body"
      "comments"
      "projectCards"
      "projectItems"
      "reactionGroups")))
  "List of json fields automatically enabled on demand in github queries.

See `om-dash-github-fields' for more details."
  :package-version '(om-dash . "0.1")
  :group 'om-dash
  :type '(alist :key-type (choice (const :tag "Pull Request" pullreq)
                                  (const :tag "Issue" issue))
                :value-type (repeat :tag "Field" string)))

(defcustom om-dash-github-sub-issue-indent "  "
  "Indentation added to titles of sub-issues per nesting level.
Used when sub-issues are nested under their parents (see `:sub-issues'
parameter of `om-dash-github')."
  :package-version '(om-dash . "0.7")
  :group 'om-dash
  :type 'string)

(defcustom om-dash-github-sub-issue-prefix "↳ "
  "Prefix added to titles of nested sub-issues, after indentation."
  :package-version '(om-dash . "0.7")
  :group 'om-dash
  :type 'string)

(defcustom om-dash-github-project-status-field "Status"
  "Name of the single-select field used as “status“ of v2 project items.

Used when `om-dash-github' lists items of a v2 project without `:repo'
\(see `:owner' and `:project' parameters).  Can be overridden per-block
using `:project-status-field' parameter."
  :package-version '(om-dash . "0.7")
  :group 'om-dash
  :type 'string)

(defcustom om-dash-imap-default-server
  '( :host nil
     :port nil
     :machine nil
     :user nil
     :password nil
     :stream nil
     :auth nil )
  "Default IMAP connection settings.

Fields from this `plist' are used in `om-dash-imap' if corresponding
parameters are not explicitly specified for the block.

Supported properties:

| parameter | description                 |
|-----------+-----------------------------|
| :host     | IMAP server hostmame        |
| :port     | IMAP server port            |
| :machine  | machine name in ~/.authinfo |
| :user     | IMAP username               |
| :password | IMAP password               |
| :stream   | STREAM for `imap-open'      |
| :auth     | AUTH for `imap-open'        |"
  :package-version '(om-dash . "0.4")
  :group 'om-dash
  :type `(plist :options
                ((:host (string :tag "Hostname Or IP"))
                 (:port (choice (integer :tag "Port Number")
                                (const :tag "Auto" nil)))
                 (:machine (choice (string :tag "Machine Name For ~/.authinfo")
                                   (const :tag "Auto" nil)))
                 (:user (choice (string :tag "User")
                                (const :tag "Auto" nil)))
                 (:password (choice (string :tag "Password")
                                    (const :tag "Auto" nil)))
                 (:stream ,(append '(choice)
                                   (seq-map (lambda (s) `(const ,s)) imap-streams)
                                   '((const :tag "Auto" nil))))
                 (:auth ,(append '(choice)
                                 (seq-map (lambda (s) `(const ,s)) imap-authenticators)
                                 '((const :tag "Auto" nil)))))))


(defcustom om-dash-imap-empty-folders nil
  "Whether to display empty IMAP folders.
If nil, empty folders are excluded from the table."
  :package-version '(om-dash . "0.1")
  :group 'om-dash
  :type 'boolean)

(defvar om-dash-imap-host nil
  "OBSOLETE.  Use `:host' property of `om-dash-imap-default-server'.")

(make-obsolete-variable
 'om-dash-imap-host
 'om-dash-imap-default-server "0.4")

(defvar om-dash-imap-port nil
  "OBSOLETE.  Use `:port' property of `om-dash-imap-default-server'.")

(make-obsolete-variable
 'om-dash-imap-port
 'om-dash-imap-default-server "0.4")

(defvar om-dash-imap-machine nil
  "OBSOLETE.  Use `:machine' property of `om-dash-imap-default-server'.")

(make-obsolete-variable
 'om-dash-imap-machine
 'om-dash-imap-default-server "0.4")

(defvar om-dash-imap-user nil
  "OBSOLETE.  Use `:user' property of `om-dash-imap-default-server'.")

(make-obsolete-variable
 'om-dash-imap-user
 'om-dash-imap-default-server "0.4")

(defvar om-dash-imap-password nil
  "OBSOLETE.  Use `:password' property of `om-dash-imap-default-server'.")

(make-obsolete-variable
 'om-dash-imap-password
 'om-dash-imap-default-server "0.4")

(defvar om-dash-imap-stream nil
  "OBSOLETE.  Use `:stream' property of `om-dash-imap-default-server'.")

(make-obsolete-variable
 'om-dash-imap-stream
 'om-dash-imap-default-server "0.4")

(defvar om-dash-imap-auth nil
  "OBSOLETE.  Use `:auth' property of `om-dash-imap-default-server'.")

(make-obsolete-variable
 'om-dash-imap-auth
 'om-dash-imap-default-server "0.4")

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

(defun om-dash--canon-type (type)
  "Map type to canonical form."
  (cond ((eq type 'pr)
         (warn "om-dash: 'pr is deprecated, use 'pullreq instead.")
         'pullreq)
        (t type)))

(defun om-dash--plist-obsolete (plist key obsolete-key)
  "Get property by key or by deprecated key."
  (or (plist-get plist key)
      (when-let ((value (plist-get plist obsolete-key)))
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
  (when-let ((seq
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

(defconst om-dash--status-faces-property "OM_DASH_STATUS_FACES"
  "Property declaring faces for project statuses in `om-dash-mode'.

Value is a list of pairs: status name (string) followed by a face
symbol or a color string (used as foreground), e.g.:

  :OM_DASH_STATUS_FACES:  \"Todo\" \"gray60\" \"In Progress\" warning
  :OM_DASH_STATUS_FACES+: \"Done\" success

The property is looked up with inheritance, so it can be set on the
heading containing a table, on any of its ancestors, or for the whole
file with “#+PROPERTY: OM_DASH_STATUS_FACES ...“.  The nearest value
is used; statuses not listed there fall back to `om-dash-status-faces'.")

(defvar om-dash--status-faces-cache nil
  "Hash table: heading position -> parsed status faces.
Bound during one font-lock pass, so the property is read once per heading.")

(defun om-dash--parse-status-faces (str)
  "Parse value of `om-dash--status-faces-property' into an assoc list."
  (when (and str (s-present-p str))
    (let ((items (condition-case nil
                     (read (concat "(" str ")"))
                   (error
                    (message "Om-dash: can't parse %s: %S"
                             om-dash--status-faces-property str)
                    nil)))
          result)
      (while (and items (cdr items))
        (when (stringp (car items))
          (push (cons (car items) (cadr items)) result))
        (setq items (cddr items)))
      (nreverse result))))

(defun om-dash--status-faces-at-point ()
  "Return status faces declared for the heading at point (with inheritance)."
  (save-match-data
    (save-excursion
      (let ((key (if (org-before-first-heading-p)
                     0
                   (org-back-to-heading t)
                   (point))))
        (let ((cached (if om-dash--status-faces-cache
                          (gethash key om-dash--status-faces-cache 'none)
                        'none)))
          (if (not (eq cached 'none))
              cached
            (let ((faces (om-dash--parse-status-faces
                          (org-entry-get nil om-dash--status-faces-property t))))
              (when om-dash--status-faces-cache
                (puthash key faces om-dash--status-faces-cache))
              faces)))))))

(defun om-dash--choose-status-face (status)
  "Select face for project STATUS name at point, or nil if not declared."
  (when (s-present-p status)
    (om-dash--face-spec
     (or (cdr (assoc-string status (om-dash--status-faces-at-point)))
         (cdr (assoc-string status om-dash-status-faces))))))

(defun om-dash--status-face-p (status)
  "Check if STATUS has a face declared."
  (and (om-dash--choose-status-face status) t))

(defun om-dash--choose-level ()
  "Select default outline level for a table."
  (save-excursion
    (while (om-dash--in-dblock-p)
      (org-previous-visible-heading 1))
    (1+ (org-outline-level))))

(cl-defstruct om-dash--cell
  "Struct that represents single table cell."
  text
  link)

(defun om-dash--format-tags (tags)
  "Format list of tags into string."
  ;; remap and remove tags according to om-dash-tag-map
  (setq tags
        (seq-remove 'not
                    (seq-map (lambda (tag)
                               (let ((mapping (assoc tag om-dash-tag-map)))
                                 (if mapping
                                     (if (listp (cdr mapping))
                                         (cadr mapping)
                                       (cdr mapping))
                                   tag)))
                             tags)))
  ;; fix tags names
  (setq tags (seq-map (lambda (tag)
                        (s-replace-regexp "[^[:alnum:]_@#%:]" "_" tag))
                      tags))
  ;; format tagline
  (if tags
      (s-concat ":" (s-join ":" tags) ":")
    ""))

(defun om-dash--format-cell (text link width)
  "Format cell contents into string."
  (when (> (length text) width)
    (setq text (s-truncate width text)))
  (let ((padding
         (if (< (length text) width)
             (s-repeat (- width (length text)) " ")
           "")))
    (cond ((or (not link)
               ;; link with empty description is not a valid org link
               (s-blank-p text)
               (eq :none (or om-dash-table-link-style :none)))
           (format "%s%s" text padding))
          ((eq :text om-dash-table-link-style)
           (format "[[%s][%s]]%s" link text padding))
          ((eq :cell om-dash-table-link-style)
           (format "[[%s][%s%s]]" link text padding))
          (t
           (user-error "Om-dash: unknown om-dash-table-link-style %S"
                       om-dash-table-link-style)))))

(defconst om-dash--heading-property "OM_DASH_HEADING"
  "Property that enables todo keyword updates of a heading.

When the heading containing an om-dash block has this property set
\(e.g. “:OM_DASH_HEADING: t“), updating the block sets todo keyword of
that heading to reflect the block's state: e.g. “TODO“ if there are
open topics, “DONE“ otherwise.  Headings without it are never touched.")

(defun om-dash--heading-enabled-p ()
  "Check if heading at point has `om-dash--heading-property' enabled."
  (when-let ((value (org-entry-get nil om-dash--heading-property)))
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

(defun om-dash--insert-caption (keyword headline)
  "Insert “#+CAPTION:“ line for a table, for blocks with several tables."
  (insert (format "#+CAPTION: %s %s\n" keyword headline)))

(defun om-dash--insert-indent (_level)
  "Insert initial indentation of table lines.
Tables are generated at column 0; `org-update-dblock' then indents
block contents to the column of “#+BEGIN:“ line, so tables are aligned
with the block they belong to."
  nil)

(defun om-dash--insert-header (cols)
  "Insert table header according to columns spec."
  (dolist (col cols)
    (let ((text (car col))
          (width (cdr col)))
      (insert "|")
      (insert (s-concat " " (s-pad-right width " " text) " "))))
  (insert "|\n"))

(defun om-dash--insert-ruler (cols)
  "Insert table ruler according to columns spec."
  (let ((col-num 0))
    (dolist (col cols)
      (let ((_text (car col))
            (width (cdr col)))
        (if (eq col-num 0)
            (insert "|")
          (insert "+"))
        (insert (s-repeat (+ 2 width) "-")))
      (setq col-num (1+ col-num))))
  (insert "|\n"))

(defun om-dash--insert-cell (cell width)
  "Insert table cell, performing truncation, padding, and formatting link."
  (let* ((text (or (om-dash--cell-text cell) ""))
         (link (om-dash--cell-link cell))
         (contents
          (om-dash--format-cell text link width)))
    (insert contents)))

(defun om-dash--insert-row (cols cells)
  "Insert table row according to columns spec and cell values."
  (let ((pos 0))
    (dolist (cell cells)
      (let ((column-width (cdr (elt cols pos))))
        (insert "| ")
        (om-dash--insert-cell cell column-width)
        (insert " ")
        (setq pos (1+ pos))))
    (insert "|\n")))

(defun om-dash--insert-table (column-names rows level &optional groups)
  "Generate table from column names and list of rows.
If GROUPS is non-nil, it's a list of group keys, one per row; a ruler
is inserted between rows whose group keys differ."
  (let* (;; index of column to stretch - by default last one
         (stretch-col (1- (length column-names)))
         ;; list of pairs ("title" . length)
         (columns (seq-map-indexed
                   (lambda (name index)
                     (when (consp name)
                       ;; if column name is ("name" . t) instead of "name",
                       ;; it means that this is the column to stretch when
                       ;; we need to fit required table width
                       (when (cdr name)
                         (setq stretch-col index))
                       (setq name (car name)))
                     (cons name (length name)))
                   column-names)))
    ;; squeeze - remove empty columns
    (when om-dash-table-squeeze-empty
      (let ((col-count (length columns)))
        (dotimes (idx col-count)
          (let ((col-num (- col-count idx 1)))
            (unless (seq-some (lambda (row)
                                (not (s-blank-str-p (om-dash--cell-text
                                                     (elt row col-num)))))
                              rows)
              ;; this column is empty, remove it
              (setq columns
                    (om-dash--remove-nth columns col-num))
              (setq rows
                    (seq-map (lambda (row)
                               (om-dash--remove-nth row col-num))
                             rows))
              (when (>= stretch-col col-num)
                (setq stretch-col (1- stretch-col))))))))
    ;; adjust column widths to fit contents
    (dolist (row rows)
      (let* ((col-num 0))
        (dolist (cell row)
          (let* ((cell-text (or (om-dash--cell-text cell) ""))
                 (cell-len (length cell-text))
                 (col-name (car (elt columns col-num)))
                 (col-width (cdr (elt columns col-num))))
            (if (> cell-len col-width)
                (setcdr (assoc col-name columns) cell-len)))
          (setq col-num (1+ col-num)))))
    ;; stretch - truncate or pad one column to fit total table width
    (when om-dash-table-fixed-width
      (let ((total-width 1))
        (dolist (col columns)
          (setq total-width (+ total-width 3 (cdr col))))
        (when (not (eq total-width om-dash-table-fixed-width))
          (let ((col (elt columns stretch-col)))
            (setcdr col (- om-dash-table-fixed-width
                           (- total-width (cdr col))))))))
    ;; |--------|
    (om-dash--insert-indent level)
    (om-dash--insert-ruler columns)
    ;; | header |
    (om-dash--insert-indent level)
    (om-dash--insert-header columns)
    ;; |--------|
    (om-dash--insert-indent level)
    (om-dash--insert-ruler columns)
    ;; |  cell  |
    ;; (with |----| between groups)
    (let ((prev-group nil)
          (first t))
      (dolist (row rows)
        (let ((group (car groups)))
          (when (and groups (not first) (not (equal group prev-group)))
            (om-dash--insert-indent level)
            (om-dash--insert-ruler columns))
          (setq prev-group group
                first nil
                groups (cdr groups)))
        (om-dash--insert-indent level)
        (om-dash--insert-row columns row)))
    ;; |--------|
    (om-dash--insert-indent level)
    (om-dash--insert-ruler columns)))

(defun om-dash--insert-newline ()
  "If current line is not empty, insert LF."
  (unless (bolp)
    (insert "\n")))

(defun om-dash--remove-empty-line ()
  "If current line is empty, remove it."
  (when (bolp)
    (delete-char -1)))

(defun om-dash--table-todo-p (table)
  "Check if a table has a cell with value from `om-dash-todo-keywords'."
  (seq-some (lambda (row)
              (seq-some (lambda (cell)
                          (seq-contains-p (om-dash--todo-keywords)
                                          (om-dash--cell-text cell)))
                        row))
            table))

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

(defun om-dash--parse-json (columns raw-output)
  "Parse json output to table."
  (let ((parsed-output (json-read-from-string raw-output))
        table)
    (seq-do (lambda (json)
              (let ((col-num 0)
                    row)
                (dolist (col columns)
                  (let* ((field (format "%s"
                                        (cdr (assoc (intern col) json)))))
                    (push (make-om-dash--cell :text field)
                          row))
                  (setq col-num (1+ col-num)))
                (push (nreverse row)
                      table)))
            parsed-output)
    (nreverse table)))

(defun om-dash--parse-csv (columns raw-output)
  "Parse csv output to table."
  (unless (featurep 'parse-csv)
    (error "Om-dash: parse-csv package not found"))
  (let ((parsed-output (parse-csv-string-rows raw-output ?\, ?\" "\n"))
        table)
    (dolist (parsed-row parsed-output)
      (when (seq-some 's-present-p parsed-row)
        (let ((col-num 0)
              row)
          (dolist (_col columns)
            (let ((field (if (< col-num (length parsed-row))
                             (elt parsed-row col-num)
                           "")))
              (push (make-om-dash--cell :text field)
                    row))
            (setq col-num (1+ col-num)))
          (push (nreverse row)
                table))))
    (nreverse table)))

(defun om-dash--parse-link (link)
  "Parse org link."
  (if (string-match org-link-bracket-re (s-trim link))
      (cons (match-string 1 link) (match-string 2 link))
    nil))

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
         (if-let ((template-name (plist-get params :template)))
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

(defun om-dash--gh-quote-arg (str)
  "Quote argument of github query search term."
  (s-replace "\"" "\\\""
             (s-replace "\\" "\\\\" str)))

(defun om-dash--gh-map-fields (field-map type)
  "Get field list from map by topic type."
  (let* ((type (om-dash--canon-type type))
         (key (if (eq type 'pullreq)
                  (if (assoc 'pr field-map)
                      (progn
                        (warn "om-dash: 'pr is deprecated, use 'pullreq instead.")
                        'pr)
                    'pullreq)
                type)))
    (cdr (assoc key field-map))))

(defun om-dash--gh-build-fields-arg (type selector fields extra-fields)
  "Construct fields list for gh command."
  ;; if user didn't provide :fields, construct them automatically
  (unless fields
    ;; add all fields enabled by default
    (setq fields
          (om-dash--gh-map-fields om-dash-github-fields type))
    (if selector
        ;; add all fields that are disabled by default but are
        ;; present in jq selector
        (dolist (field
                 (om-dash--gh-map-fields om-dash-github-auto-enabled-fields type))
          (if (s-contains-p field selector)
              (setq fields
                    (append fields (list field)))))))
  (seq-uniq (append fields
                    extra-fields)))

(defun om-dash--gh-build-search-arg (state query)
  "Construct query for gh --search option."
  (let ((sub-queries
         (list (pcase state
                 (`any nil)
                 (`open "state:open")
                 (`closed "-state:open")
                 (_ (user-error "Om-dash: bad state %S" state)))
               (cond
                ;; "*"
                ((string= "*" query) "")
                ;; "-123d"
                ((when-let ((timestamp (om-dash--parse-reltime query)))
                   (format "updated:>=%s" timestamp)))
                ;; passthrough
                (t query)))))
    (s-join " " (seq-remove 's-blank-p sub-queries))))

(defun om-dash--gh-build-command (repo type state filter fields extra-fields limit)
  "Construct gh command."
  (let ((type (om-dash--canon-type type))
        (query (car filter))
        (selector (cadr filter))
        command)
    (when (s-present-p query)
      (let ((fields
             (s-join "," (om-dash--gh-build-fields-arg type selector fields extra-fields)))
            (subcmd (pcase type
                      (`pullreq "pr")
                      (`issue "issue")
                      (_ (user-error "Om-dash: bad :type %S" type))))
            (search
             (om-dash--gh-build-search-arg state query)))
        (setq command (format
                       "gh %s -R %s list --state all --json %s --search %s --limit %s"
                       subcmd
                       (om-dash--shell-quote repo)
                       (om-dash--shell-quote fields)
                       (om-dash--shell-quote search)
                       (om-dash--shell-quote limit))))
      (when (s-present-p selector)
        (let ((expr (format "[.[] | select(%s)]"
                            selector)))
          (setq command (format "%s | jq %s"
                                command
                                (om-dash--shell-quote expr)))))
      command)))

(defun om-dash--jq-build-command (input-files sort-by)
  "Constructs jq command that joins and sorts output of gh commands."
  (let* ((merge-expr
          (s-join " + " (seq-map
                         (lambda (index) (format ".[%d]" index))
                         (number-sequence 0 (1- (length input-files))))))
         (sort-by (format "%s" sort-by))
         (descending (s-starts-with-p "-" sort-by))
         (field (if descending (substring sort-by 1) sort-by))
         (expr
          (format "%s | sort_by(.%s)%s"
                  merge-expr
                  field
                  (if descending " | reverse" ""))))
    (format "jq -s %s %s"
            (om-dash--shell-quote expr)
            (s-join " " (seq-map 'om-dash--shell-quote input-files)))))

(defun om-dash--github-build-extra-fields (table-columns)
  "Determine what additional github fields to we need to request."
  (seq-remove
   'not (list
         (when (seq-contains-p table-columns :reviewer)
           "reviewRequests")
         (when (or (seq-contains-p table-columns :project)
                   (seq-contains-p table-columns :project-status))
           "projectItems")
         (when (or (seq-contains-p table-columns :classic-project)
                   (seq-contains-p table-columns :classic-project-status))
           "projectCards"))))

(defun om-dash--github-read-topics (repo type any-filter open-filter closed-filter
                                         sort-by fields table-columns limit)
  "Construct and run command for om-dash-github."
  (let* ((extra-fields
          (om-dash--github-build-extra-fields table-columns))
         (gh-types
          (if (eq type 'any) (list 'pullreq 'issue)
            (list type)))
         (gh-commands
          (seq-remove 'not
                      (apply 'append
                             (seq-map
                              (lambda (type)
                                (list
                                 (om-dash--gh-build-command ;  :any
                                  repo type 'any any-filter fields extra-fields limit)
                                 (om-dash--gh-build-command ;  :open
                                  repo type 'open open-filter fields extra-fields limit)
                                 (om-dash--gh-build-command ;  :closed
                                  repo type 'closed closed-filter fields extra-fields limit)))
                              gh-types))))
         (gh-outputs
          (seq-map (lambda (_cmd) (make-temp-file "om-dash-"))
                   gh-commands))
         (jq-command
          (om-dash--jq-build-command gh-outputs sort-by)))
    (unwind-protect
        (progn
          ;; run gh commands, save output to temp files
          (seq-mapn (lambda (cmd out)
                      (let ((gh-command
                             (format "%s > %s" cmd out)))
                        (om-dash--shell-run gh-command nil)))
                    gh-commands
                    gh-outputs)
          ;; run jq command to merge and sort gh outputs, and return result
          (om-dash--shell-run jq-command t))
      ;; delete temp files
      (dolist (out gh-outputs)
        (delete-file out)))))

;;; Project mode: list items of a v2 project without :repo.

(defvar om-dash--github-owner-type-cache (make-hash-table :test 'equal)
  "Cache of github owner login -> owner type (`user' or `organization').")

(defun om-dash--github-owner-type (owner forced-type)
  "Determine whether OWNER is a user, an organization, or viewer (“@me“).
If FORCED-TYPE is non-nil, use it instead of auto-detection."
  (cond
   ((string= owner "@me") 'viewer)
   (forced-type
    (pcase forced-type
      (`user 'user)
      ((or `org `organization) 'organization)
      (_ (user-error "Om-dash: bad :owner-type %S" forced-type))))
   ((gethash owner om-dash--github-owner-type-cache))
   (t
    (let* ((out (s-trim
                 (om-dash--shell-run
                  (format "gh api %s --jq .type"
                          (om-dash--shell-quote (format "users/%s" owner)))
                  t)))
           (type (if (string= out "Organization") 'organization 'user)))
      (puthash owner type om-dash--github-owner-type-cache)
      type))))

(defun om-dash--github-project-graphql (owner-type status-field)
  "Build GraphQL query that lists all items of a v2 project.
Includes issues (with parent and sub-issue summary), pull requests,
and draft issues."
  (let* ((common-fields
          (s-concat
           "number title url state createdAt updatedAt closedAt "
           "repository { nameWithOwner } author { login } "
           "assignees(first: 20) { nodes { login } } "
           "labels(first: 50) { nodes { name } } "
           "milestone { title } "))
         (project-body
          (format
           (s-concat
            "projectV2(number: $number) { title url "
            "items(first: 100, after: $endCursor) { "
            "pageInfo { hasNextPage endCursor } "
            "nodes { id databaseId "
            "status: fieldValueByName(name: \"%s\") { "
            "... on ProjectV2ItemFieldSingleSelectValue { name } } "
            "content { __typename "
            "... on Issue { %s "
            "parent { url number } "
            "subIssuesSummary { total completed } } "
            "... on PullRequest { %s "
            "mergedAt isDraft reviewDecision "
            "reviewRequests(first: 20) { nodes { requestedReviewer { "
            "... on User { login } ... on Team { name } } } } "
            "reviews(first: 50) { nodes { state author { login } } } } "
            "... on DraftIssue { title createdAt updatedAt "
            "creator { login } "
            "assignees(first: 20) { nodes { login } } } "
            "} } } }")
           (om-dash--gh-quote-arg status-field)
           common-fields
           common-fields)))
    (pcase owner-type
      (`viewer
       (format "query($number: Int!, $endCursor: String) { viewer { %s } }"
               project-body))
      (_
       (format "query($owner: String!, $number: Int!, $endCursor: String) { %s(login: $owner) { %s } }"
               (symbol-name owner-type)
               project-body)))))

(defconst om-dash--github-project-normalize-jq
  (s-concat
   "[.[] | .data | (.user // .organization // .viewer) | .projectV2 as $p"
   " | $p.items.nodes[]"
   " | select(.content.__typename == \"Issue\""
   " or .content.__typename == \"PullRequest\""
   " or .content.__typename == \"DraftIssue\")"
   " | .status as $s | .id as $item_id | .databaseId as $item_dbid"
   " | .content"
   " | (.__typename == \"DraftIssue\") as $draft"
   " | {_type: (if .__typename == \"PullRequest\" then \"pullreq\" else \"issue\" end),"
   " number: (.number // null),"
   " title,"
   ;; draft issues have no url; link to the item in the project, and
   ;; keep item node id in url fragment for om-dash commands
   " url: (if $draft"
   " then \"\\($p.url)?pane=issue&itemId=\\($item_dbid)#om-dash-item=\\($item_id)\""
   " else .url end),"
   " state: (if $draft then \"DRAFT\" else .state end),"
   " createdAt, updatedAt,"
   " closedAt: (.closedAt // null),"
   " mergedAt: (.mergedAt // null),"
   " isDraft: (.isDraft // false),"
   " isDraftIssue: $draft,"
   " repository: (.repository.nameWithOwner // null),"
   " author: (.author // .creator // null),"
   " assignees: [(.assignees.nodes // [])[]],"
   " labels: [(.labels.nodes // [])[]],"
   " milestone: (.milestone // null),"
   " parent: (.parent // null),"
   " subIssuesSummary: (.subIssuesSummary // null),"
   " reviewDecision: (.reviewDecision // \"\"),"
   " reviewRequests: [(.reviewRequests.nodes // [])[]"
   " | .requestedReviewer | select(. != null) | {login: (.login // .name)}],"
   " reviews: (.reviews.nodes // []),"
   " projectItems: [{title: $p.title, status: {name: ($s.name // \"\")}}]}]")
  "Jq expression that converts paginated GraphQL output into a list of topics.
The resulting objects have the same shape as `gh pr list --json' output,
plus `parent' and `subIssuesSummary' for issues.  Draft issues have
state “DRAFT“, no number, and url pointing to the project item.")

(defun om-dash--gh-split-terms (str separators)
  "Split STR by any char from SEPARATORS, ignoring separators inside quotes."
  (let ((terms nil)
        (cur nil)
        (in-quotes nil)
        (escaped nil))
    (seq-do (lambda (ch)
              (cond
               (escaped
                (push ch cur)
                (setq escaped nil))
               ((and in-quotes (eq ch ?\\))
                (push ch cur)
                (setq escaped t))
               ((eq ch ?\")
                (push ch cur)
                (setq in-quotes (not in-quotes)))
               ((and (not in-quotes) (memq ch separators))
                (when cur
                  (push (apply #'string (nreverse cur)) terms))
                (setq cur nil))
               (t
                (push ch cur))))
            str)
    (when cur
      (push (apply #'string (nreverse cur)) terms))
    (nreverse terms)))

(defun om-dash--gh-unquote (str)
  "Remove surrounding quotes and backslash escapes from STR."
  (if (and (>= (length str) 2)
           (s-starts-with-p "\"" str)
           (s-ends-with-p "\"" str))
      (replace-regexp-in-string "\\\\\\(.\\)" "\\1"
                                (substring str 1 -1) t)
    str))

(defun om-dash--jq-str (str)
  "Format STR as jq string literal."
  (format "\"%s\"" (om-dash--gh-quote-arg str)))

(defun om-dash--jq-date-cmp (field expr)
  "Build jq selector comparing FIELD with github date EXPR (e.g. “>=2024-01-01“)."
  (let ((cmp (lambda (op ts)
               (let ((ts (or (om-dash--parse-reltime ts) ts)))
                 (format "(.%s != null and (.%s[0:%d] %s %s))"
                         field field (length ts) op (om-dash--jq-str ts))))))
    (cond
     ((string-match "^\\(.+\\)\\.\\.\\(.+\\)$" expr)
      (let ((from (match-string 1 expr))
            (to (match-string 2 expr)))
        (om-dash--join " and "
                       (unless (string= from "*") (funcall cmp ">=" from))
                       (unless (string= to "*") (funcall cmp "<=" to)))))
     ((string-match "^\\(>=\\|<=\\|>\\|<\\)\\(.+\\)$" expr)
      (funcall cmp (match-string 1 expr) (match-string 2 expr)))
     (t
      (funcall cmp "==" expr)))))

(defun om-dash--gh-term-to-jq (key values)
  "Translate one github search qualifier KEY:VALUES into jq selector."
  (let ((any-of (lambda (fmt)
                  (format "(%s)"
                          (s-join " or "
                                  (seq-map (lambda (v)
                                             (format fmt (om-dash--jq-str v)))
                                           values)))))
        (value (car values)))
    (pcase key
      ;; state:open, state:closed, is:open, is:merged, ...
      ((or "state" "is")
       (pcase value
         ("open" "(.state == \"OPEN\" or .state == \"DRAFT\")")
         ("closed" "(.state != \"OPEN\" and .state != \"DRAFT\")")
         ("merged" "(.state == \"MERGED\")")
         ("unmerged" "(.state == \"CLOSED\")")
         ;; draft pull request or draft issue
         ("draft" "(.isDraft == true or .state == \"DRAFT\")")
         ("pr" "(._type == \"pullreq\")")
         ("issue" "(._type == \"issue\")")
         (_ (user-error "Om-dash: unsupported %s:%s without :repo" key value))))
      ("type"
       (pcase value
         ("pr" "(._type == \"pullreq\")")
         ("issue" "(._type == \"issue\")")
         (_ (user-error "Om-dash: unsupported type:%s without :repo" value))))
      ("no"
       (pcase value
         ("milestone" "(.milestone == null)")
         ("label" "(.labels == [])")
         ("assignee" "(.assignees == [])")
         (_ (user-error "Om-dash: unsupported no:%s without :repo" value))))
      ("milestone"
       (if (string= value "*")
           "(.milestone != null)"
         (funcall any-of "(.milestone.title == %s)")))
      ("label"
       (if (string= value "*")
           "(.labels != [])"
         (funcall any-of "any(.labels[]; .name == %s)")))
      ("author"
       (funcall any-of "(.author.login == %s)"))
      ("assignee"
       (if (string= value "*")
           "(.assignees != [])"
         (funcall any-of "any(.assignees[]; .login == %s)")))
      ("repo"
       (funcall any-of "(.repository == %s)"))
      ("created" (om-dash--jq-date-cmp "createdAt" value))
      ("updated" (om-dash--jq-date-cmp "updatedAt" value))
      ("closed" (om-dash--jq-date-cmp "closedAt" value))
      ("merged" (om-dash--jq-date-cmp "mergedAt" value))
      ;; already applied by fetching project items
      ("project" nil)
      (_ (user-error "Om-dash: github qualifier %s: is not supported without :repo"
                     key)))))

(defun om-dash--gh-query-to-jq (query)
  "Translate github search QUERY into jq selector (used without :repo).

Supports “*“, relative timestamps like “-1w“, free text (matched against
title), and qualifiers: state, is, type, no, milestone, label, author,
assignee, repo, created, updated, closed, merged, project (ignored).
Qualifiers may be negated with “-“.  Repeated author: and assignee:
qualifiers are ORed, everything else is ANDed, same as on github."
  (cond
   ((or (not query) (s-blank-p query) (string= query "*"))
    nil)
   ((om-dash--parse-reltime query)
    (om-dash--jq-date-cmp "updatedAt" (format ">=%s" query)))
   (t
    (let (and-exprs author-exprs assignee-exprs)
      (dolist (term (om-dash--gh-split-terms query '(?\s ?\t ?\n)))
        (if (string-match "^\\(-?\\)\\([a-z]+\\):\\(.+\\)$" term)
            (let* ((negate (string= (match-string 1 term) "-"))
                   (key (match-string 2 term))
                   (values (seq-map #'om-dash--gh-unquote
                                    (om-dash--gh-split-terms
                                     (match-string 3 term) '(?,))))
                   (expr (om-dash--gh-term-to-jq key values)))
              (when expr
                (cond
                 (negate
                  (push (format "(%s | not)" expr) and-exprs))
                 ((string= key "author")
                  (push expr author-exprs))
                 ((and (string= key "assignee")
                       (not (string= (car values) "*")))
                  (push expr assignee-exprs))
                 (t
                  (push expr and-exprs)))))
          ;; free text: match title, case-insensitive
          (let ((word (om-dash--gh-unquote term)))
            (push (format "(.title | ascii_downcase | contains(%s))"
                          (om-dash--jq-str (downcase word)))
                  and-exprs))))
      (when author-exprs
        (push (format "(%s)" (s-join " or " (nreverse author-exprs))) and-exprs))
      (when assignee-exprs
        (push (format "(%s)" (s-join " or " (nreverse assignee-exprs))) and-exprs))
      (om-dash--join " and " (nreverse and-exprs))))))

(defun om-dash--github-read-project-topics (owner owner-type project status-field
                                                  type any-filter open-filter
                                                  closed-filter sort-by limit)
  "Read topics from v2 PROJECT of OWNER, without being bound to a repo."
  (let* ((owner-type (om-dash--github-owner-type owner owner-type))
         (graphql (om-dash--github-project-graphql owner-type status-field))
         (fetch-command
          (format "gh api graphql --paginate -f %s %s-F %s | jq -s %s"
                  (om-dash--shell-quote (format "query=%s" graphql))
                  (if (eq owner-type 'viewer)
                      ""
                    (format "-F %s "
                            (om-dash--shell-quote (format "owner=%s" owner))))
                  (om-dash--shell-quote (format "number=%s" project))
                  (om-dash--shell-quote om-dash--github-project-normalize-jq)))
         (gh-types (if (eq type 'any)
                       (list 'pullreq 'issue)
                     (list (om-dash--canon-type type))))
         ;; list of jq expressions, one per (type, state) pair
         (jq-exprs
          (seq-remove
           'not
           (apply 'append
                  (seq-map
                   (lambda (gh-type)
                     (seq-map
                      (lambda (state-and-filter)
                        (let* ((state (car state-and-filter))
                               (filter (cdr state-and-filter))
                               (query (car filter))
                               (selector (cadr filter)))
                          (when (s-present-p query)
                            (format "[.[] | select(%s)] | sort_by(.createdAt) | reverse | .[:%s]"
                                    (om-dash--join
                                     " and "
                                     (format "(._type == \"%s\")" gh-type)
                                     (pcase state
                                       (`any nil)
                                       ;; draft issues are considered open
                                       (`open "(.state == \"OPEN\" or .state == \"DRAFT\")")
                                       (`closed "(.state != \"OPEN\" and .state != \"DRAFT\")"))
                                     (when-let ((expr (om-dash--gh-query-to-jq query)))
                                       (format "(%s)" expr))
                                     (when (s-present-p selector)
                                       (format "(%s)" selector)))
                                    limit))))
                      (list (cons 'any any-filter)
                            (cons 'open open-filter)
                            (cons 'closed closed-filter))))
                   gh-types))))
         (all-items (make-temp-file "om-dash-"))
         (outputs (seq-map (lambda (_expr) (make-temp-file "om-dash-"))
                           jq-exprs)))
    (unwind-protect
        (progn
          ;; fetch all project items once
          (om-dash--shell-run (format "%s > %s"
                                      fetch-command
                                      (om-dash--shell-quote all-items))
                              nil)
          ;; filter items for every (type, state) pair
          (seq-mapn (lambda (expr out)
                      (om-dash--shell-run
                       (format "jq %s %s > %s"
                               (om-dash--shell-quote expr)
                               (om-dash--shell-quote all-items)
                               (om-dash--shell-quote out))
                       nil))
                    jq-exprs
                    outputs)
          ;; merge and sort
          (if outputs
              (om-dash--shell-run (om-dash--jq-build-command outputs sort-by) t)
            "[]"))
      (dolist (file (cons all-items outputs))
        (delete-file file)))))

(defun om-dash--github-q-milestone (params)
  "Build queries for :milestone and :no-milestone."
  (let* ((match-list (if-let ((param (plist-get params :milestone)))
                         (cond ((listp param) param)
                               ((stringp param) (list param))
                               (t (user-error
                                   "Om-dash: bad :milestone parameter %S" param)))))
         (ignore-list (if-let ((param (plist-get params :no-milestone)))
                          (cond ((listp param) param)
                                ((stringp param) (list param))
                                (t (user-error
                                    "Om-dash: bad :no-milestone parameter %S" param)))))
         (gh-query
          ;; :milestone
          ;; note: github doesn't support multiple "milestone:" queries,
          ;;       hence this case is handled in jq below
          (when (eq (length match-list) 1)
            (pcase (car match-list)
              ;; only include topics with non-empty milestone
              ("*" "milestone:*")
              ;; only include topics with empty milestone
              ("-" "no:milestone")
              ;; only include topics with specified milestone
              (_ (format "milestone:\"%s\""
                         (om-dash--gh-quote-arg (car match-list)))))))
         (jq-selector
          (om-dash--join
           " and "
           ;; :milestone
           (when (> (length match-list) 1)
             (format "(%s)"
                     (om-dash--join
                      " or "
                      (seq-map
                       (lambda (elem)
                         (pcase elem
                           ;; only include topics with non-empty milestone
                           ("*" "(.milestone != null)")
                           ;; only include topics with empty milestone
                           ("-" "(.milestone == null)")
                           ;; only include topics with specified milestone
                           (_ (format "(.milestone.title == \"%s\")"
                                      (om-dash--gh-quote-arg elem)))))
                       match-list))))
           ;; :no-milestone
           (seq-map
            (lambda (elem)
              (pcase elem
                ;; exclude topics with non-empty milestone
                ("*" "(.milestone == null)")
                ;; exclude topics with empty milestone
                ("-" "(.milestone != null)")
                ;; exclude topics with specified milestone
                (_ (format "(.milestone.title != \"%s\")"
                           (om-dash--gh-quote-arg elem)))))
            ignore-list))))
    (list gh-query jq-selector)))

(defun om-dash--github-q-label (params)
  "Build queries for :label and :no-label."
  (let* ((any-list (if-let ((param (plist-get params :label)))
                       (cond ((listp param) param)
                             ((stringp param) (list param))
                             (t (user-error
                                 "Om-dash: bad :label parameter %S" param)))))
         (every-list (if-let ((param (plist-get params :every-label)))
                         (cond ((listp param) param)
                               ((stringp param) (list param))
                               (t (user-error
                                   "Om-dash: bad :every-label parameter %S" param)))))
         (ignore-list (if-let ((param (plist-get params :no-label)))
                          (cond ((listp param) param)
                                ((stringp param) (list param))
                                (t (user-error
                                    "Om-dash: bad :no-label parameter %S" param)))))
         (gh-query
          (om-dash--join
           " "
           ;; :label
           (when (and any-list
                      (not (om-dash--contains-p any-list "*" "-")))
             ;; include topic if it has any of the labels from list
             ;; note: comma-separated label names inside "label:" query are ORed
             ;; note: github doesn't support ORing label names with "*" and "-",
             ;;       so these cases are handled in jq below
             (format "label:%s"
                     (om-dash--join
                      "," (seq-map (lambda (elem)
                                     (format "\"%s\"" (om-dash--gh-quote-arg elem)))
                                   any-list))))
           ;; :every-label
           ;; note: space-separated "label:" github queries are ANDed
           (seq-map
            (lambda (elem)
              (unless (or (string= elem "*")
                          (string= elem "-"))
                ;; include topic if it has all of the labels from list
                (format "label:\"%s\""
                        (om-dash--gh-quote-arg elem))))
            every-list)))
         (jq-selector
          (om-dash--join
           " and "
           ;; :label
           (when (and any-list
                      (om-dash--contains-p any-list "*" "-"))
             ;; include topic if it has any of the labels from list
             (format "(%s)"
                     (om-dash--join
                      " or "
                      (seq-map
                       (lambda (elem)
                         (pcase elem
                           ;; match topics with non-empty labels
                           ("*" "(.labels != [])")
                           ;; match topics with empty labels
                           ("-" "(.labels == [])")
                           ;; match topics with specified label
                           (_ (format "any(.labels[]; .name == \"%s\")"
                                      (om-dash--gh-quote-arg elem)))))
                       any-list))))
           ;; :every-label
           (seq-map
            (lambda (elem)
              (pcase elem
                ;; only include topics with non-empty labels
                ("*" "(.labels != [])")
                ;; only include topics with empty labels
                ("-" "(.labels == [])")))
            every-list)
           ;; :no-label
           (seq-map
            (lambda (elem)
              (pcase elem
                ;; exclude topics with non-empty labels
                ("*" "(.labels == [])")
                ;; exclude topics with empty labels
                ("-" "(.labels != [])")
                ;; exclude topics with specific label
                (_ (format "all(.labels[]; .name != \"%s\")"
                           (om-dash--gh-quote-arg elem)))))
            ignore-list))))
    (list gh-query jq-selector)))

(defun om-dash--github-q-author (params)
  "Build queries for :author and :no-author."
  (let* ((match-list (if-let ((param (plist-get params :author)))
                         (cond ((listp param) param)
                               ((stringp param) (list param))
                               (t (user-error
                                   "Om-dash: bad :author parameter %S" param)))))
         (ignore-list (if-let ((param (plist-get params :no-author)))
                          (cond ((listp param) param)
                                ((stringp param) (list param))
                                (t (user-error
                                    "Om-dash: bad :no-author parameter %S" param)))))
         (gh-query
          ;; :author
          ;; note: space-separated "author:" github queries are ORed
          ;; note: github doesn't support "author:*" and "no:author", so
          ;;       hence these cases are handled in jq below
          ;;       (though they are probably impossible in practice)
          (when (and match-list
                     (not (om-dash--contains-p match-list "*" "-")))
            (om-dash--join
             " " (seq-map
                  (lambda (elem)
                    ;; only include topics with specific author
                    (format "author:\"%s\""
                            (om-dash--gh-quote-arg elem)))
                  match-list))))
         (jq-selector
          (om-dash--join
           " and "
           ;; :author
           (when (and match-list
                      (om-dash--contains-p match-list "*" "-"))
             ;; include topic if it has any of the authors from list
             (format "(%s)"
                     (om-dash--join
                      " or "
                      (seq-map
                       (lambda (elem)
                         (pcase elem
                           ;; match topics with non-empty author
                           ("*" "(.author != null)")
                           ;; match topics with non author
                           ("-" "(.author == null)")
                           ;; match topics with specified author
                           (_ (format "(.author.login == \"%s\")"
                                      (om-dash--gh-quote-arg elem)))))
                       match-list))))
           ;; :no-author
           (seq-map
            (lambda (elem)
              (pcase elem
                ;; exclude topics with non-empty author
                ("*" "(.author == null)")
                ;; exclude topics with empty author
                ("-" "(.author != null)")
                ;; exclude topics with specific author
                (_ (format "(.author.login != \"%s\")"
                           (om-dash--gh-quote-arg elem)))))
            ignore-list))))
    (list gh-query jq-selector)))

(defun om-dash--github-q-assignee (params)
  "Build queries for :assignee and :no-assignee."
  (let* ((match-list (if-let ((param (plist-get params :assignee)))
                         (cond ((listp param) param)
                               ((stringp param) (list param))
                               (t (user-error
                                   "Om-dash: bad :assignee parameter %S" param)))))
         (ignore-list (if-let ((param (plist-get params :no-assignee)))
                          (cond ((listp param) param)
                                ((stringp param) (list param))
                                (t (user-error
                                    "Om-dash: bad :no-assignee parameter %S" param)))))
         (gh-query
          (om-dash--join
           ;; :assignee
           ;; note: space-separated "assignee:" github queries are ORed
           " " (seq-map
                (lambda (elem)
                  (pcase elem
                    ;; only include topics with non-empty assignee
                    ("*" "assignee:*")
                    ;; only include topics with empty assignee
                    ("-" "no:assignee")
                    ;; only include topics with specified assignee
                    (_ (format "assignee:\"%s\""
                               (om-dash--gh-quote-arg elem)))))
                match-list)))
         (jq-selector
          ;; :no-assignee
          (when ignore-list
            (om-dash--join
             " and " (seq-map
                      (lambda (elem)
                        (pcase elem
                          ;; exclude topics with non-empty assignee
                          ("*" "(.assignees == [])")
                          ;; exclude topics with empty assignee
                          ("-" "(.assignees != [])")
                          ;; exclude topics with specified assignee
                          (_ (format "all(.assignees[]; .login != \"%s\")"
                                     (om-dash--gh-quote-arg elem)))))
                      ignore-list)))))
    (list gh-query jq-selector)))

(defun om-dash--github-q-reviewer (params)
  "Build queries for :reviewer and :no-reviewer."
  (let* ((match-list (if-let ((param (plist-get params :reviewer)))
                         (cond ((listp param) param)
                               ((stringp param) (list param))
                               (t (user-error
                                   "Om-dash: bad :reviewer parameter %S" param)))))
         (ignore-list (if-let ((param (plist-get params :no-reviewer)))
                          (cond ((listp param) param)
                                ((stringp param) (list param))
                                (t (user-error
                                    "Om-dash: bad :no-reviewer parameter %S" param)))))
         (match-expr
          ;; :reviewer
          (when match-list
            (om-dash--join
             " or " (seq-map
                     (lambda (elem)
                       (pcase elem
                         ;; only include topics with non-empty reviewers
                         ("*" "(.reviewRequests != [])")
                         ;; only include topics with empty reviewers
                         ("-" "(.reviewRequests == [])")
                         ;; only include topics with specified reviewer
                         (_ (format "any(.reviewRequests[]; .login == \"%s\")"
                                    (om-dash--gh-quote-arg elem)))))
                     match-list))))
         (ignore-expr
          ;; :no-reviewer
          (when ignore-list
            (om-dash--join
             " and " (seq-map
                      (lambda (elem)
                        (pcase elem
                          ;; exclude topics with non-empty reviewers
                          ("*" "(.reviewRequests == [])")
                          ;; exclude topics with empty reviewers
                          ("-" "(.reviewRequests != [])")
                          ;; exclude topics with specified reviewer
                          (_ (format "all(.reviewRequests[]; .login != \"%s\")"
                                     (om-dash--gh-quote-arg elem)))))
                      ignore-list))))
         (jq-selector
          (om-dash--join
           " and " (seq-map (lambda (expr)
                              (format "(%s)" expr))
                            (seq-remove 'not
                                        (list match-expr ignore-expr))))))
    (list nil jq-selector)))

(defun om-dash--github-q-review-status (params)
  "Build queries for :review-status and :no-review-status."
  (let* ((match-list (if-let ((param (plist-get params :review-status)))
                         (cond ((listp param) param)
                               ((symbolp param) (list param))
                               (t (user-error
                                   "Om-dash: bad :review-status %S" param)))))
         (ignore-list (if-let ((param (plist-get params :no-review-status)))
                          (cond ((listp param) param)
                                ((symbolp param) (list param))
                                (t (user-error
                                    "Om-dash: bad :no-review-status %S" param)))))
         ;; 2-element list:
         ;;   - elem 0: expression list for match-list
         ;;   - elem 1: expression list for ignore-list
         (expr-lists
          (seq-map
           (lambda (status-list)
             (seq-map
              (lambda (status)
                (pcase status
                  ;; undecided: no review decision, no review requests, if there are
                  ;;            reviews, then only in COMMENTED or PENDING states
                  (`undecided
                   (s-concat
                    ".reviewDecision == \"\""
                    " and "
                    ".reviewRequests == []"
                    " and "
                    "all(.reviews[]; .state | IN(\"COMMENTED\", \"PENDING\"))"))
                  ;; required: review decision is REVIEW_REQUIRED
                  (`required
                   ".reviewDecision == \"REVIEW_REQUIRED\"")
                  ;; requested: at least one review request
                  (`requested
                   ".reviewRequests != []")
                  ;; commented: at least one review with COMMENTED state
                  (`commented
                   "any(.reviews[]; .state == \"COMMENTED\")")
                  ;; approved: all reviews are either in APPROVED or COMMENTED
                  ;;           state, and at least one of them is APPROVED
                  (`approved
                   (s-concat
                    "any(.reviews[]; .state == \"APPROVED\")"
                    " and "
                    "all(.reviews[]; .state | IN(\"APPROVED\", \"COMMENTED\"))"))
                  ;; rejected: at least one review in CHANGES_REQUESTED or
                  ;;           DISMISSED state
                  (`rejected
                   "any(.reviews[]; .state | IN(\"CHANGES_REQUESTED\", \"DISMISSED\"))")
                  (_
                   (user-error "Om-dash: bad :review-status %S" status))))
              status-list))
           (list match-list
                 ignore-list)))
         ;; :review-status
         (match-exprs (car expr-lists))
         (match-selector
          (om-dash--join " or "
                         (seq-map (lambda (expr)
                                    (format "(%s)" expr))
                                  (seq-remove 'not
                                              match-exprs))))
         ;; :no-review-status
         (ignore-exprs (cadr expr-lists))
         (ignore-selector
          (om-dash--join " and "
                         (seq-map (lambda (expr)
                                    (format "((%s) | not)" expr))
                                  (seq-remove 'not
                                              ignore-exprs))))
         ;; combined
         (jq-selector
          (om-dash--join " and "
                         (seq-map (lambda (selector)
                                    (format "(%s)" selector))
                                  (seq-remove 'not
                                              (list match-selector
                                                    ignore-selector))))))
    (list nil jq-selector)))

(defun om-dash--github-q-project (params)
  "Build query for :project, :project-type, :project-status :no-project-status."
  (let* ((repo (plist-get params :repo))
         (owner (or (plist-get params :owner)
                    (when repo (car (s-split "/" repo)))))
         (project (plist-get params :project))
         (project-type (or (plist-get params :project-type) 'v2))
         (match-status (if-let ((param (plist-get params :project-status)))
                           (cond ((listp param) param)
                                 (t (list param)))))
         (ignore-status (if-let ((param (plist-get params :no-project-status)))
                            (cond ((listp param) param)
                                  (t (list param)))))
         (gh-query
          ;; :project
          (when project
            ;; only include topics with specified project
            (format "project:%s/%s"
                    (pcase project-type
                      (`v2 owner)
                      (`classic repo)
                      (_ (user-error "Om-dash: bad project type %S" project-type)))
                    project)))
         (jq-selector
          (om-dash--join
           " and "
           ;; :project-status
           (om-dash--join
            " or "
            (seq-map (lambda (status)
                       (pcase project-type
                         ;; only include topics with specified status name
                         (`v2
                          (format "any(.projectItems[]; .status.name == \"%s\")"
                                  (om-dash--gh-quote-arg status)))
                         ;; only include topics with specified column name
                         (`classic
                          (format "any(.projectCards[]; .column.name == \"%s\")"
                                  (om-dash--gh-quote-arg status)))
                         (_
                          (user-error "Om-dash: bad project type %S" project-type))))
                     match-status))
           (seq-map (lambda (status)
                      (pcase project-type
                        ;; exclude topics with specified status name
                        (`v2
                         (format "all(.projectItems[]; .status.name != \"%s\")"
                                 (om-dash--gh-quote-arg status)))
                        ;; exclude  topics with specified column name
                        (`classic
                         (format "all(.projectCards[]; .column.name != \"%s\")"
                                 (om-dash--gh-quote-arg status)))
                        (_
                         (user-error "Om-dash: bad project type %S" project-type))))
                    ignore-status))))
    (list gh-query jq-selector)))

(defun om-dash--github-q-timestamp (params)
  "Build queries for :created-at, :updated-at, :closed-at, :merged-at."
  (let* ((created-at (plist-get params :created-at))
         (updated-at (plist-get params :updated-at))
         (closed-at (plist-get params :closed-at))
         (merged-at (plist-get params :merged-at))
         (gh-query
          (om-dash--join
           ;; note: space-separated "created:", "updated:", and "closed:"
           ;;       github queries are ANDed
           " " (cl-mapcar
                (lambda (name query)
                  (cond
                   ;; string, e.g. "2024-02-20" or "-100d"
                   ((stringp query)
                    (let ((timestamp (or (om-dash--parse-reltime query)
                                         query)))
                      (format "%s:%s" name timestamp)))
                   ;; 2-element list, e.g. (> "2024-02-20")
                   ((and (listp query) (eq (length query) 2))
                    (let ((operator (nth 0 query))
                          (timestamp (or (om-dash--parse-reltime (nth 1 query))
                                         (nth 1 query))))
                      (pcase operator
                        (`> (format "%s:>%s" name timestamp))
                        (`>= (format "%s:>=%s" name timestamp))
                        (`< (format "%s:<%s" name timestamp))
                        (`<= (format "%s:<=%s" name timestamp))
                        (_ (user-error "Om-dash: bad :%s-at" name)))))
                   ;; 3-element list, e.g. (range "2024-01-01" "2024-02-20")
                   ((and (listp query) (eq (length query) 3))
                    (let ((operator (nth 0 query))
                          (timestamp-1 (or (om-dash--parse-reltime (nth 1 query))
                                           (nth 1 query)))
                          (timestamp-2 (or (om-dash--parse-reltime (nth 2 query))
                                           (nth 2 query))))
                      (pcase operator
                        (`range (format "%s:%s..%s" name timestamp-1 timestamp-2))
                        (_ (user-error "Om-dash: bad :%s-at" name)))))
                   ;; not given
                   ((not query)
                    nil)
                   ;; unrecognized
                   (t
                    (user-error "Om-dash: bad :%s-at" name))))
                (list "created" "updated" "closed" "merged")
                (list created-at updated-at closed-at merged-at)))))
    (list gh-query nil)))

(defun om-dash--github-build-query (params plist)
  "Build gh and jq queries from plist."
  (let* (;; build sub-queries for all supported parameters
         ;; query-list is a list of pairs (gh-query jq-selector)
         ;; some elements are nil/blank when corresponding parameters
         ;; not given, we filter them out below
         (subquery-list
          (seq-map (lambda (build-func)
                     (apply build-func (append plist params) nil))
                   (list
                    #'om-dash--github-q-milestone
                    #'om-dash--github-q-label
                    #'om-dash--github-q-author
                    #'om-dash--github-q-assignee
                    #'om-dash--github-q-reviewer
                    #'om-dash--github-q-review-status
                    #'om-dash--github-q-project
                    #'om-dash--github-q-timestamp)))
         ;; join all non-empty github sub-queries
         (gh-query
          (let ((query
                 (s-join " "
                         (seq-remove 's-blank-p
                                     (seq-map (lambda (query)
                                                (nth 0 query))
                                              subquery-list)))))
            (if (s-present-p query)
                query
              ;; default github query is "*" (fetch all)
              "*")))
         ;; join all non-empty jq sub-selectors
         (jq-selector
          (let ((selector
                 (s-join " and "
                         (seq-map (lambda (expr)
                                    (format "(%s)" expr))
                                  (seq-remove 's-blank-p
                                              (seq-map (lambda (query)
                                                         (nth 1 query))
                                                       subquery-list))))))
            (if (s-present-p selector)
                selector
              ;; default jq selector is empty (no filtering)
              ""))))
    (list gh-query jq-selector)))

(defun om-dash--github-format-assignee (json)
  "Format assignee name(s) of github topic."
  (let ((assignee-list (seq-map (lambda (user)
                                  (format "@%s" (cdr (assoc 'login user))))
                                (cdr (assoc 'assignees json)))))
    (when assignee-list
      (s-join "," assignee-list))))

(defun om-dash--github-format-reviewer (json)
  "Format reviewer name(s) of github topic."
  (let ((reviewer-list (seq-uniq
                        (seq-map (lambda (request)
                                   (format "@%s" (cdr (assoc 'login request))))
                                 (cdr (assoc 'reviewRequests json))))))
    (when reviewer-list
      (s-join "," reviewer-list))))

(defun om-dash--github-format-v2-project (json)
  "Format v2 project name(s) and project status(es) associated with topic."
  (when-let ((project-items (cdr (assoc 'projectItems json))))
    (let* ((project-list
            (seq-remove 's-blank-p
                        (seq-uniq (seq-map (lambda (item)
                                             (cdr (assoc 'title item)))
                                           project-items))))
           (status-list
            (seq-remove 's-blank-p
                        (seq-uniq (seq-map (lambda (item)
                                             (cdr (assoc 'name (cdr (assoc 'status item)))))
                                           project-items)))))
      (list (when project-list
              (s-join ", " project-list))
            (when status-list
              (s-join ", " status-list))))))

(defun om-dash--github-format-classic-project (json)
  "Format classic project name(s) and project column(s) associated with topic."
  (when-let ((project-cards (cdr (assoc 'projectCards json))))
    (let* ((project-list
            (seq-remove 's-blank-p
                        (seq-uniq (seq-map (lambda (item)
                                             (cdr (assoc 'name (cdr (assoc 'project item)))))
                                           project-cards))))
           (column-list
            (seq-remove 's-blank-p
                        (seq-uniq (seq-map (lambda (item)
                                             (cdr (assoc 'name (cdr (assoc 'column item)))))
                                           project-cards)))))
      (list (when project-list
              (s-join ", " project-list))
            (when column-list
              (s-join ", " column-list))))))

(defun om-dash--github-format-timestamp (date)
  "Re-format github timestamp."
  (when date
    (if-let ((ts (ts-parse date)))
        (ts-format om-dash-table-time-format ts)
      date)))

(defun om-dash--github-format-headline (type)
  "Get headline from github type."
  (let ((type (om-dash--canon-type type)))
    (pcase type
      (`issue "issues")
      (`pullreq "pull requests")
      (`any "issues and pull requests")
      (_ (user-error "Om-dash: bad type %S" type)))))

(defun om-dash--github-nest-topics (topics)
  "Order TOPICS so that sub-issues follow their parent issues.

Returns list of (TOPIC . DEPTH).  A topic is nested under its parent
if the parent is also present in TOPICS; otherwise it's a top-level
row.  Order of TOPICS (i.e. `:sort') is kept among top-level rows and
among children of the same parent.  Nesting can be arbitrarily deep."
  (let ((topics (append topics nil))
        (by-url (make-hash-table :test 'equal))
        (children (make-hash-table :test 'equal))
        roots
        result)
    (dolist (topic topics)
      (puthash (cdr (assoc 'url topic)) topic by-url))
    (dolist (topic topics)
      (let ((parent-url (cdr (assoc 'url (cdr (assoc 'parent topic))))))
        (if (and parent-url
                 (gethash parent-url by-url)
                 (not (equal parent-url (cdr (assoc 'url topic)))))
            (puthash parent-url
                     (append (gethash parent-url children) (list topic))
                     children)
          (push topic roots))))
    (cl-labels ((walk (topic depth)
                  (push (cons topic depth) result)
                  ;; depth limit guards against malformed (cyclic) data
                  (when (< depth 50)
                    (dolist (child (gethash (cdr (assoc 'url topic)) children))
                      (walk child (1+ depth))))))
      (dolist (root (nreverse roots))
        (walk root 0)))
    (nreverse result)))

(defun om-dash--github-nested-title (title depth)
  "Format TITLE of a sub-issue at nesting DEPTH (0 for top-level rows)."
  (if (and title (> depth 0))
      (concat (s-repeat (1- depth) om-dash-github-sub-issue-indent)
              om-dash-github-sub-issue-prefix
              title)
    title))

(defun om-dash--sort-groups (rows order)
  "Stable sort ROWS, a list of (GROUP-KEY . CELLS), by group key.

ORDER is one of:
 - `asc'  - groups in alphabetical order
 - `desc' - groups in reverse alphabetical order
 - `sort' - groups in order of their first row (i.e. follow `:sort')

In all cases rows with empty group key (e.g. draft issues without repo)
go last.  Order of rows inside each group is preserved."
  (let ((first-seen (make-hash-table :test 'equal))
        (index 0))
    (dolist (row rows)
      (unless (gethash (car row) first-seen)
        (puthash (car row) index first-seen))
      (setq index (1+ index)))
    (seq-sort
     (lambda (a b)
       (let ((ka (car a))
             (kb (car b)))
         (cond ((s-blank-p ka) nil)
               ((s-blank-p kb) t)
               (t (pcase order
                    (`asc (string< ka kb))
                    (`desc (string< kb ka))
                    (`sort (< (gethash ka first-seen)
                              (gethash kb first-seen)))
                    (_ (user-error "Om-dash: bad :group-order %S" order)))))))
     rows)))

;;;###autoload
(defun org-dblock-write:om-dash-github (params)
  "Builds org heading with a table of github issues or pull requests.

Basic example:

  #+BEGIN: om-dash-github :repo “owner/repo“ :type issue :open “*“ :closed “-1w“
  ...
  #+END:

More complicated query using simple syntax:

  #+BEGIN: om-dash-github :repo “owner/repo“ :type pullreq :open (:milestone “1.2.3“ :label “blocker“ :no-label “triage“)
  ...
  #+END:

Same query but by providing github search query and jq selector:

  #+BEGIN: om-dash-github :repo “owner/repo“ :type pullreq :open (“milestone:1.2.3 label:blocker“ “.labels | (.name == \\“triage\\“) | not“)
  ...
  #+END:

Items of a v2 project, from any repo (no :repo needed):

  #+BEGIN: om-dash-github :owner “octocat“ :project 7 :type pullreq :open “*“ :closed “-1w“
  ...
  #+END:

Parameters:

| parameter             | default                               | description                             |
|-----------------------+---------------------------------------+-----------------------------------------|
| :repo                 | required unless :owner and :project   | github repo in form “<owner>/<repo>“    |
| :owner                | owner part of :repo                   | user, org or “@me“ owning the project   |
| :project              | nil                                   | v2 project number (project mode)        |
| :owner-type           | auto                                  | `user' or `org' (skips auto-detection)  |
| :project-status-field | `om-dash-github-project-status-field' | project field used as status            |
| :type                 | required                              | topic type (`issue', `pullreq', `any')  |
| :any                  | see below                             | query for topics in any state           |
| :open                 | see below                             | query for topics in open state          |
| :closed               | see below                             | query for topics in closed state        |
| :sort                 | “createdAt“                           | sort results by field, “-field“ = desc  |
| :group-by             | nil                                   | column to group rows by, e.g. `:repo'   |
| :group-order          | `asc'                                 | group order: `asc', `desc', `sort'      |
| :sub-issues           | `nest'                                | `nest' sub-issues under parent, `flat'  |
| :fields               | `om-dash-github-fields'               | explicitly specify list of fields       |
| :limit                | `om-dash-github-limit'                | limit number of results                 |
| :columns              | `om-dash-github-columns'              | list of columns to display              |
| :keyword              | auto                                  | keyword of OM_DASH_HEADING              |
| :headline             | auto                                  | caption of multi-table blocks           |
| :heading-level        | auto                                  | unused                                  |

Parameters `:any', `:open', and `:closed' define `QUERY' for topics in corresponding
states.  You should specify either `:any' or `:open' and/or `:close'.  Not specifying
anything is equavalent to :open “*“.

`QUERY' can have one of the following forms:

 - plist: om-dash `SIMPLE-QUERY', e.g.:
     (:milestone “1.2.3“ :no-author “bob“)

 - string: standard or extended `GITHUB-QUERY', e.g.:
     “milestone:1.2.3“
     “*“
     “-1w“

 - list: two-element list with `GITHUB-QUERY' and `JQ-SELECTOR' strings, e.g.:
     (“milestone:1.2.3“ “.author.login != “bob“)

You can specify different queries for `:open' and `:closed' topics, e.g. to show all
open issues but only recently closed issues, use:

  :open “*“ :closed “-1mo“

Or you can use a single query regardless of topic state:

  :any “-1mo“

`SIMPLE-QUERY' format is a convenient way to build queries for some typical
use cases.  The query should be a `plist' with the following properties:

| property           | description                                              |
|--------------------+----------------------------------------------------------|
| :milestone         | include only topics with any of given milestone(s)       |
| :no-milestone      | exclude topics with any of given milestone(s)            |
| :label             | include only topics with any of given label(s)           |
| :every-label       | include only topics with all of given label(s)           |
| :no-label          | exclude topics with any of given label(s)                |
| :author            | include only topics with any of given author(s)          |
| :no-author         | exclude topics with any of given author(s)               |
| :assignee          | include only topics with any of given assignee(s)        |
| :no-assignee       | exclude topics with any of given assignee(s)             |
| :reviewer          | include only topics with any of given reviewer(s)        |
| :no-reviewer       | exclude topics with any of given reviewer(s)             |
| :review-status     | include only topics with any of given review status(es)  |
| :no-review-status  | exclude topics with any of given review status(es)       |
| :project           | include only topics added to given project               |
| :project-type      | choose between v2 and classic project                    |
| :project-status    | include only topics with any of given project status(es) |
| :no-project-status | exclude topics with any of given project status(es)      |
| :created-at        | include only topics created within given date range      |
| :updated-at        | include only topics updated within given date range      |
| :closed-at         | include only topics closed within given date range       |
| :merged-at         | include only topics merged within given date range       |

All properties are optional (but at least one should be provided).  Multiple
properties are ANDed, e.g. (:author “bob“ :label “bug“) matches topics with
author “bob“ AND label “bug“.  Most properties support list form, in which case
its elements are ORed.  E.g. (:author (“bob“ “alice“) :label “bug“) matches
topics with label “bug“ AND author either “bob“ OR “alice“.

`:milestone', `:label', `:author', `:assignee', and `:reviewer' properties, as
well as their `:no-xxx' counterparts, can be either a string (to match one value)
or a list of strings (to match any value from the list).  Two special values are
supported: “*“ matches if corresponding property (e.g. assignee) is non-empty,
and “-“ matches if the property unset/empty.

Examples:
  :author “bob“
  :assignee “-“
  :no-label (“refactoring“ “documentation“)

`:every-label' is similar to `:label', but it matches topics that have all of
the labels from the list, instead of any label from list.

`:review-status' property can be a symbol or a list of symbols
\(to match any status from the list).

Supported values:

| status    | description                                                           |
|-----------+-----------------------------------------------------------------------|
| undecided | review not required, not requested, there're no approvals or rejects  |
| required  | review is required by repo rules                                      |
| requested | review is explicitly requested                                        |
| commented | some reviewers commented without approval or rejection                |
| approved  | all reviewers either approved or commented, and at least one approved |
| rejected  | some reviewers requested changes or dismissed review                  |

Examples:
  :review-status (required requested)
  :review-status approved
  :no-review-status (approved rejected commented)

GitHub review state model is complicated.  These statuses is an attempt to provide
a simplified view of the review state for most common needs.

Note that not all statuses are mutually exclusive, in particular `required' can
co-exist with any status except `undecided', and `commented' can co-exist with
any other status.  You can match multiple statuses by providing a list.

`:project' defines numeric identifier of the `v2' or `classic' github project (you can
see identifier in the url).  By default, `v2' is assumed, but you can change type
using `:project-type' property.

`:project-status' can be a string or a list of strings.  For `v2' projects, it matches
“status“ field of the project item, which corresponds to column name if board view of
the project.  For `classic' projects, it matches “column“ property of the project card.

Examples:
  :project 5 :project-status “In work“
  :project 2 :project-type classic :project-status (“Backlog“ “On hold“)

`:created-at', `:updated-at', `:closed-at', `:merged-at' can have one of this forms:
 - “TIMESTAMP“
 - (> “TIMESTAMP“)
 - (>= “TIMESTAMP“)
 - (< “TIMESTAMP“)
 - (<= “TIMESTAMP“)
 - (range “TIMESTAMP“ “TIMESTAMP“)

Supported `TIMESTAMP' formats:

| format                      | description                 |
|-----------------------------+-----------------------------|
| “2024-02-20“                | date                        |
| “2024-02-20T15:59:59Z“      | utc date and time           |
| “2024-02-20T15:59:79+00:00“ | date and time with timezone |
| “-10d“                      | 10 days before today        |
| “-10w“                      | 10 weeks before today       |
| “-10mo“                     | 10 months before today      |
| “-10y“                      | 10 years before today       |

Examples:
  :created-at “2024-02-20“
  :updated-at (>= “-3mo“)

`GITHUB-QUERY' is a string using github search syntax:
https://docs.github.com/en/search-github/searching-on-github/searching-issues-and-pull-requests

Besides standard syntax, a few extended forms are supported for github query:

| form     | description                                     |
|----------+-------------------------------------------------|
| “*“      | match all topics                                |
| “-123d“  | match if topic was updated during last 123 days |
| “-123w“  | same, but weeks                                 |
| “-123mo“ | same, but months                                |
| “-123y“  | same, but years                                 |

`JQ-SELECTOR' is an optional selector to filter results using jq command:
https://jqlang.github.io/jq/

`:group-by' is a column symbol (any from `om-dash-github-columns', e.g.
`:repo', `:state', `:milestone', `:author', `:project-status').  Rows are
grouped by the value of that column (ordered by `:group-order': `asc'
alphabetical, `desc' reverse, `sort' by first row according to `:sort';
rows with empty value, e.g. draft issues for `:repo', go last), keeping
`:sort' order inside each group, and a divider line is inserted between
groups.  The column doesn't need to be displayed.  With nested
sub-issues, each sub-issue belongs to the group of its top-level
parent, so that parent and its sub-issues stay together.

Parameters can be given inline, or in “OM_DASH_GITHUB“ (github blocks
only) and “OM_DASH“ (all om-dash blocks) properties of the enclosing
heading or any of its ancestors.  Nearer headings override outer ones,
inline parameters override properties.  E.g. owner and project can be
set once on a parent heading and reused by all child blocks:

  * Infra
  :PROPERTIES:
  :OM_DASH_GITHUB: :owner “octocat“ :project 7
  :END:
  ** TODO Pull requests
  :PROPERTIES:
  :OM_DASH_HEADING: t
  :END:
  #+BEGIN: om-dash-github :type pullreq
  #+END:

With “:OM_DASH_HEADING: t“, the block sets todo keyword of the heading
it's under (see `om-dash--heading-property').

`:sub-issues' controls how sub-issues are shown (project mode only, since
`gh issue list' doesn't report parents).  With `nest' (default), a
sub-issue is shown right after its parent, with title indented by
`om-dash-github-sub-issue-indent' per level and prefixed with
`om-dash-github-sub-issue-prefix'; nesting can be arbitrarily deep.
Sub-issues whose parent is not in the table (e.g. filtered out or not
added to the project) are shown as top-level rows.  With `flat', rows
are not reordered.  Columns `:parent' and `:sub-issues' show parent
number and “completed/total“ sub-issue counts.

`:sort' is a field name from github json (see `om-dash-github-fields'),
optionally a nested path, e.g. “updatedAt“, “number“, “author.login“,
“milestone.title“, “projectItems[0].status.name“.  Prefix it with “-“
for descending order, e.g. “-updatedAt“.

Project mode:

If `:repo' is omitted and both `:owner' and top-level `:project' are given,
the block lists issues and pull requests added to that v2 project, from
any repository.  `:owner' is the login from the project url
\(github.com/users/<owner>/projects/<N> or github.com/orgs/<owner>/projects/<N>),
or “@me“ for your own projects.  Requires “read:project“ token scope:

  gh auth refresh -s read:project

In this mode all project items are fetched once via “gh api graphql“, and
filtering is done with jq.  `GITHUB-QUERY' is translated to jq and supports:
“*“, “-1w“-style timestamps, free text (matched in title), and qualifiers
state:, is:, type:, no:, milestone:, label:, author:, assignee:, repo:,
created:, updated:, closed:, merged: (optionally negated with “-“).
`SIMPLE-QUERY' and `JQ-SELECTOR' work as usual.  `:fields' is ignored.

Draft issues of the project are included as issues with state “DRAFT“
\(considered open, i.e. matched by `:open' and “is:open“; “is:draft“
matches draft issues and draft pull requests).  They have no number or
repository, and their link opens the item in the project.
`om-dash-github-set-project-status' works for them, closing and
reopening doesn't (convert draft to issue first).
`:project-status' matches the `:project-status-field' value of the item.

Under the hood, this block uses combination of gh and jq commands like:

  gh -R <repo> issue list \\
        --json <fields> --search <github query> --limit <limit> \\
    | jq '[.[] | select(<jq selector>)]'

Exact commands being executed are printed to `*om-dash*' buffer
if `om-dash-verbose' is set.

By default, github query uses all fields from `om-dash-github-fields', plus any
field from `om-dash-github-auto-enabled-fields' if it's present in jq selector.
The latter allows to exclude fields that makes queries slower, when they're
not used.  To change this, you can specify `:fields' parameter explicitly."
  ;; expand template
  (setq params
        (om-dash--prepare-params params))
  ;; parse params
  (let* ((repo (plist-get params :repo))
         (project (plist-get params :project))
         (owner (or (plist-get params :owner)
                    (when repo (car (s-split "/" repo)))))
         (project-mode (and (not repo) project owner t))
         (owner-type (plist-get params :owner-type))
         (status-field (or (plist-get params :project-status-field)
                           om-dash-github-project-status-field))
         (_ (unless (or repo project-mode)
              (user-error "Om-dash: missing :repo (or :owner and :project)")))
         (_ (when (and project-mode
                       (eq (plist-get params :project-type) 'classic))
              (user-error "Om-dash: classic projects require :repo")))
         (type (or (plist-get params :type) (user-error "Om-dash: missing :type")))
         (any-filter (if-let ((param (plist-get params :any)))
                         (cond ((om-dash--kwlistp param)
                                (om-dash--github-build-query params param))
                               ((and (listp param) (eq (length param) 2))
                                param)
                               ((stringp param)
                                (list param nil))
                               (t (user-error "Om-dash: bad :any parameter %S" param)))))
         (open-filter (if-let ((param (plist-get params :open)))
                          (cond ((om-dash--kwlistp param)
                                 (om-dash--github-build-query params param))
                                ((and (listp param) (eq (length param) 2))
                                 param)
                                ((stringp param)
                                 (list param nil))
                                (t (user-error "Om-dash: bad :open parameter %S" param)))))
         (closed-filter (if-let ((param (plist-get params :closed)))
                            (cond ((om-dash--kwlistp param)
                                   (om-dash--github-build-query params param))
                                  ((and (listp param) (eq (length param) 2))
                                   param)
                                  ((stringp param)
                                   (list param nil))
                                  (t (user-error "Om-dash: bad :closed parameter %S" param)))))
         (sort-by (or (plist-get params :sort)
                      "createdAt"))
         (fields (plist-get params :fields))
         (limit (or (plist-get params :limit)
                    om-dash-github-limit))
         (table-columns (or (om-dash--plist-obsolete params :columns :table-columns)
                            om-dash-github-columns))
         (keyword (plist-get params :keyword))
         (headline (or (plist-get params :headline)
                       (format "%s (%s)" (om-dash--github-format-headline type)
                               (if project-mode
                                   (format "%s/projects/%s" owner project)
                                 repo))))
         (heading-level (or (plist-get params :heading-level)
                            (om-dash--choose-level)))
         (group-by (plist-get params :group-by))
         (group-order (or (plist-get params :group-order) 'asc))
         (sub-issues (or (plist-get params :sub-issues) 'nest))
         (_ (unless (memq sub-issues '(nest flat))
              (user-error "Om-dash: bad :sub-issues %S (use `nest' or `flat')"
                          sub-issues))))
    ;; validation and defaults
    (when (and (or open-filter closed-filter)
               any-filter)
      (user-error "Om-dash: :any can't be used together with :open or :closed"))
    (unless (or any-filter open-filter closed-filter)
      (setq open-filter (list "*" nil)))
    ;; build an run command
    (let* ((raw-output (if project-mode
                           (om-dash--github-read-project-topics
                            owner owner-type project status-field
                            type any-filter open-filter closed-filter
                            sort-by limit)
                         (om-dash--github-read-topics
                          repo type any-filter open-filter closed-filter
                          sort-by fields table-columns limit)))
           (parsed-output (json-read-from-string raw-output))
           (column-names
            (seq-map (lambda (col)
                       (pcase col
                         (`:state "state")
                         (`:number "no.")
                         (`:repo "repo")
                         (`:parent "parent")
                         (`:sub-issues "sub-issues")
                         ((or `:title `:title-link) '("title" . t))
                         (`:milestone "milestone")
                         (`:tags "tags")
                         (`:author "author")
                         (`:assignee "assignee")
                         (`:reviewer "reviewer")
                         ((or `:project `:classic-project) "project")
                         ((or `:project-status `:classic-project-status) "status")
                         (`:created-at "created")
                         (`:updated-at "updated")
                         (`:closed-at "closed")
                         (`:merged-at "merged")
                         (_ (user-error "Om-dash: unknown table column %S" col))))
                     table-columns))
           table
           todo-p
           make-cell
           root-group-key)
      (seq-do (lambda (entry)
                (let* ((json (car entry))
                       (depth (cdr entry))
                       (state (cdr (assoc 'state json)))
                       (number (when-let ((num (cdr (assoc 'number json))))
                                 (format "#%s" num)))
                       (parent (cdr (assoc 'parent json)))
                       (parent-number (when-let ((num (cdr (assoc 'number parent))))
                                        (format "#%s" num)))
                       (parent-url (cdr (assoc 'url parent)))
                       (sub-issues-summary
                        (let* ((summary (cdr (assoc 'subIssuesSummary json)))
                               (total (cdr (assoc 'total summary))))
                          (when (and (numberp total) (> total 0))
                            (format "%s/%s" (cdr (assoc 'completed summary)) total))))
                      (repository (or (cdr (assoc 'repository json)) repo))
                      (milestone (cdr (assoc 'title
                                             (cdr (assoc 'milestone json)))))
                      (tags (om-dash--format-tags
                             (seq-map (lambda (label) (cdr (assoc 'name label)))
                                      (cdr (assoc 'labels json)))))
                      (author (when-let ((login (cdr (assoc 'login
                                                            (cdr (assoc 'author json))))))
                                (format "@%s" login)))
                      (assignee (om-dash--github-format-assignee json))
                      (reviewer (om-dash--github-format-reviewer json))
                      (v2-project (om-dash--github-format-v2-project json))
                      (classic-project (om-dash--github-format-classic-project json))
                      (title (om-dash--github-nested-title
                              (cdr (assoc 'title json)) depth))
                      (url (cdr (assoc 'url json)))
                      (created-at (om-dash--github-format-timestamp
                                   (cdr (assoc 'createdAt json))))
                      (updated-at (om-dash--github-format-timestamp
                                   (cdr (assoc 'updatedAt json))))
                      (closed-at (om-dash--github-format-timestamp
                                  (cdr (assoc 'closedAt json))))
                      (merged-at (om-dash--github-format-timestamp
                                  (cdr (assoc 'mergedAt json)))))
                  (if (seq-contains-p (om-dash--todo-keywords) state)
                      (setq todo-p t))
                  (setq make-cell
                        (lambda (col)
                              (pcase col
                                (`:state (make-om-dash--cell :text state))
                                (`:number (make-om-dash--cell :text number :link url))
                                (`:repo (make-om-dash--cell :text repository))
                                (`:parent (make-om-dash--cell :text parent-number
                                                              :link parent-url))
                                (`:sub-issues (make-om-dash--cell :text sub-issues-summary))
                                (`:title (make-om-dash--cell :text title))
                                (`:title-link (make-om-dash--cell :text title :link url))
                                (`:milestone (make-om-dash--cell :text milestone))
                                (`:tags (make-om-dash--cell :text tags))
                                (`:author (make-om-dash--cell :text author))
                                (`:assignee (make-om-dash--cell :text assignee))
                                (`:reviewer (make-om-dash--cell :text reviewer))
                                (`:project (make-om-dash--cell :text (car v2-project)))
                                (`:project-status (make-om-dash--cell :text (cadr v2-project)))
                                (`:classic-project (make-om-dash--cell :text (car classic-project)))
                                (`:classic-project-status (make-om-dash--cell
                                                           :text (cadr classic-project)))
                                (`:created-at (make-om-dash--cell :text created-at))
                                (`:updated-at (make-om-dash--cell :text updated-at))
                                (`:closed-at (make-om-dash--cell :text closed-at))
                                (`:merged-at (make-om-dash--cell :text merged-at))
                                (_ (user-error "Om-dash: unknown table column %S" col)))))
                  ;; group key: sub-issues use the key of their top-level
                  ;; parent, so that each tree stays within one group
                  (when (and group-by (eq depth 0))
                    (setq root-group-key
                          (or (om-dash--cell-text (funcall make-cell group-by))
                              "")))
                  (push (cons (when group-by root-group-key)
                              (seq-map make-cell table-columns))
                        table)))
              (if (eq sub-issues 'nest)
                  (om-dash--github-nest-topics parsed-output)
                (seq-map (lambda (json) (cons json 0)) parsed-output)))
      (setq table (nreverse table))
      ;; group rows: stable sort by group key, so :sort order is kept
      ;; within each group
      (when group-by
        (setq table (om-dash--sort-groups table group-order)))
      (om-dash--insert-heading (or keyword
                                   (om-dash--choose-keyword todo-p))
                               headline heading-level)
      (when table
        (om-dash--insert-table column-names
                               (seq-map #'cdr table)
                               heading-level
                               (when group-by (seq-map #'car table))))
      (om-dash--remove-empty-line))))

(defun om-dash-github:milestone (params)
  "This template is OBSOLETE.
Use `om-dash-github' with `:milestone' query instead."
  ;; parse args
  (let* ((repo (or (plist-get params :repo) (user-error "Om-dash: missing :repo")))
         (type (or (plist-get params :type) (user-error "Om-dash: missing :type")))
         (state (or (plist-get params :state) 'open))
         (milestone (or (plist-get params :milestone)
                        (user-error "Om-dash: missing :milestone")))
         (headline (or (plist-get params :headline)
                       (format "%s (%s \"%s\")"
                               (om-dash--github-format-headline type)
                               repo
                               milestone)))
         (heading-level (or (plist-get params :heading-level)
                            (om-dash--choose-level))))
    ;; build query
    (let ((query
           (om-dash--github-q-milestone (list :milestone milestone))))
      ;; return modified parameters
      (append
       (list :headline headline
             :heading-level heading-level)
       (pcase state
         (`any `(:any ,query))
         (`open `(:open ,query :closed ""))
         (`closed `(:open "" :closed ,query)))))))

(make-obsolete
 'om-dash-github:milestone
 'org-dblock-write:om-dash-github "0.3")

(defun om-dash-github:project-column (params)
  "This template is OBSOLETE.
Use `om-dash-github' with `:project-status' query instead."
  ;; parse args
  (let* ((repo (or (plist-get params :repo) (user-error "Om-dash: missing :repo")))
         (type (or (plist-get params :type) (user-error "Om-dash: missing :type")))
         (state (or (plist-get params :state) 'open))
         (project (or (plist-get params :project)
                      (user-error "Om-dash: missing :project")))
         (column (or (plist-get params :column)
                     (user-error "Om-dash: missing :column")))
         (headline (or (plist-get params :headline)
                       (format "%s (%s \"%s\")"
                               (om-dash--github-format-headline type)
                               repo
                               column)))
         (heading-level (or (plist-get params :heading-level)
                            (om-dash--choose-level))))
    ;; build query
    (let ((query
           (om-dash--github-q-project
            (list :repo repo
                  :project project
                  :project-type 'classic
                  :project-status column))))
      ;; return modified parameters
      (append
       (list :headline headline
             :heading-level heading-level)
       (pcase state
         (`any `(:any ,query))
         (`open `(:open ,query :closed ""))
         (`closed `(:open "" :closed ,query)))))))

(make-obsolete
 'om-dash-github:project-column
 'org-dblock-write:om-dash-github "0.3")

(defun om-dash--orgfile-q-nth-parent (depth pred)
  "Build `org-ql' query that applies predicate to Nth parent."
  (while (> depth 0)
    (setq pred (list 'parent pred))
    (setq depth (1- depth)))
  pred)

(defun om-dash--orgfile-q-and (sub-queries)
  "Build `org-ql' query by ANDing non-nil sub-queries."
  (let ((sub-queries (seq-remove 'not sub-queries)))
    (pcase (length sub-queries)
      (0 nil)
      (1 (car sub-queries))
      (_ (append '(and) sub-queries)))))

(defun om-dash--orgfile-q-or (sub-queries)
  "Build `org-ql' query by ORing non-nil sub-queries."
  (let ((sub-queries (seq-remove 'not sub-queries)))
    (pcase (length sub-queries)
      (0 nil)
      (1 (car sub-queries))
      (_ (append '(or) sub-queries)))))

(defun om-dash--orgfile-q-keyword (keywords)
  "Build `org-ql' query to match entry keyword."
  (append '(todo) keywords))

(defun om-dash--orgfile-q-flags (blocked habit)
  "Build `org-ql' query to match entry blocked and habit flag."
  (when (or blocked habit)
    (om-dash--orgfile-q-and
     (list
      (pcase blocked
        (`nil nil)
        (`any nil)
        (`yes '(blocked))
        (`no '(not (blocked)))
        (_ (user-error "Om-dash: bad :blocked value %S" blocked)))
      (pcase habit
        (`nil nil)
        (`any nil)
        (`yes '(habit))
        (`no '(not (habit)))
        (_ (user-error "Om-dash: bad :habit value %S" habit)))))))

(defun om-dash--orgfile-q-category (any-category no-category)
  "Build `org-ql' query to match entry category."
  (when (or any-category no-category)
    (om-dash--orgfile-q-and
     (list
      (when any-category
        (append '(category) any-category))
      (when no-category
        `(not ,(append '(category) no-category)))))))

(defun om-dash--orgfile-q-priority (any-priority no-priority)
  "Build `org-ql' query to match entry priority."
  (when (or any-priority no-priority)
    (om-dash--orgfile-q-and
     (list
      (when any-priority
        (append '(priority) any-priority))
      (when no-priority
        `(not ,(append '(priority) no-priority)))))))

(defun om-dash--orgfile-q-tag (any-tag every-tag no-tag)
  "Build `org-ql' query for tags."
  (when (or any-tag every-tag no-tag)
    (om-dash--orgfile-q-and
     (list
      (when any-tag
        (append '(tags) any-tag))
      (when every-tag
        (append '(tags-all) every-tag))
      (when no-tag
        `(not ,(append '(tags) no-tag)))))))

(defun om-dash--orgfile-build-subquery (plist depth keywords)
  "Construct `org-ql' query for TODO or DONE entries."
  ;; parse parameters
  (let* ((blocked (plist-get plist :blocked))
         (habit (plist-get plist :habit))
         (any-category (if-let ((param (plist-get plist :category)))
                           (cond ((listp param) param)
                                 ((stringp param) (list param))
                                 (t (user-error
                                     "Om-dash: bad :category parameter %S" param)))))
         (no-category (if-let ((param (plist-get plist :no-category)))
                          (cond ((listp param) param)
                                ((stringp param) (list param))
                                (t (user-error
                                    "Om-dash: bad :no-category parameter %S" param)))))
         (any-priority (if-let ((param (plist-get plist :priority)))
                           (cond ((listp param) param)
                                 ((stringp param) (list param))
                                 (t (user-error
                                     "Om-dash: bad :priority parameter %S" param)))))
         (no-priority (if-let ((param (plist-get plist :no-priority)))
                          (cond ((listp param) param)
                                ((stringp param) (list param))
                                (t (user-error
                                    "Om-dash: bad :no-priority parameter %S" param)))))
         (any-tag (if-let ((param (plist-get plist :tag)))
                      (cond ((listp param) param)
                            ((stringp param) (list param))
                            (t (user-error
                                "Om-dash: bad :tag parameter %S" param)))))
         (every-tag (if-let ((param (plist-get plist :every-tag)))
                        (cond ((listp param) param)
                              ((stringp param) (list param))
                              (t (user-error
                                  "Om-dash: bad :every-tag parameter %S" param)))))
         (no-tag (if-let ((param (plist-get plist :no-tag)))
                     (cond ((listp param) param)
                           ((stringp param) (list param))
                           (t (user-error
                               "Om-dash: bad :no-tag parameter %S" param)))))
         ;; query to match keyword of top-level entry
         (kw-query (om-dash--orgfile-q-keyword keywords))
         ;; query to match parameters of nested entries
         (filter-query (om-dash--orgfile-q-and
                        (list
                         (om-dash--orgfile-q-flags blocked habit)
                         (om-dash--orgfile-q-category any-category no-category)
                         (om-dash--orgfile-q-priority any-priority no-priority)
                         (om-dash--orgfile-q-tag any-tag every-tag no-tag))))
         ;; query to list level 1 entries
         (level-1-query
          (when (>= depth 1)
            (om-dash--orgfile-q-and `((level 1)
                                      ,kw-query
                                      ,filter-query))))
         ;; queries to list level 2..depth entries
         (level-n-queries
          (seq-map
           (lambda (depth) (om-dash--orgfile-q-and
                            `((level ,depth)
                              ,(om-dash--orgfile-q-nth-parent (1- depth) kw-query)
                              ,filter-query)))
           (number-sequence 2 depth))))
    ;; combine queries
    (om-dash--orgfile-q-or (append (list level-1-query)
                                   level-n-queries))))

(defun om-dash--orgfile-build-query (plist)
  "Construct `org-ql' query from plist."
  (let* ((todo-depth (or (plist-get plist :todo-depth) 2))
         (done-depth (or (plist-get plist :done-depth) 1))
         (todo-query
          (om-dash--orgfile-build-subquery plist todo-depth (om-dash--todo-keywords)))
         (done-query
          (om-dash--orgfile-build-subquery plist done-depth (om-dash--done-keywords))))
    (om-dash--orgfile-q-or (list todo-query
                                 done-query))))

(defun om-dash--orgfile-run-query (path query digest)
  "Construct and run `org-ql' query for `om-dash-orgfile'."
  (om-dash--log
   (format "%s: %S" path query))
  (let ((entries (org-ql-select path query)))
    (if digest
        (seq-map (lambda (entry)
                   (let ((entry (org-element-copy entry)))
                     (org-element-put-property
                      entry :level (1+ (org-element-property :level entry)))
                     entry))
                 entries)
      entries)))

(defun om-dash--orgfile-leveled-keyword (keyword level)
  "Format entry for keyword column in `om-dash-orgfile' block."
  (let ((padding
         (if (> level 2)
             (s-repeat (* (- level 2) 1) " ")
           "")))
    (s-concat padding keyword)))

(defun om-dash--orgfile-leveled-title (title level)
  "Format entry for title column in `om-dash-orgfile' block."
  (let ((padding
         (if (> level 2)
             (s-concat
              (s-repeat (* (- level 2) 2) " ")
              "* ")
           "")))
    (s-concat padding title)))

;; Make byte compiler happy.
(declare-function org-ql--normalize-query "org-ql" t t)

;;;###autoload
(defun org-dblock-write:om-dash-orgfile (params)
  "Builds org headings with tables based on another org file.

Basic usage:

  #+BEGIN: om-dash-orgfile :file “~/my/file.org“ :query (:todo-depth 2 :done-depth 1)
  ...
  #+END:

Custom org-ql query:

  #+BEGIN: om-dash-orgfile :file “~/my/file.org“ :query (todo “SOMEDAY“)
  ...
  #+END:

Parameters:

| parameter      | default                       | description                            |
|----------------+-------------------------------+----------------------------------------|
| :file          | required                      | path to .org file                      |
| :query         | (:todo-depth 2 :done-depth 1) | query for org entries                  |
| :digest        | nil                           | generate single table with all entries |
| :columns       | `om-dash-orgfile-columns'     | list of columns to display             |
| :keyword       | auto                          | keyword of OM_DASH_HEADING             |
| :headline      | auto                          | caption of multi-table blocks          |
| :heading-level | auto                          | unused                                 |

By default, this block generates an org heading with a table for every
top-level (i.e. level-1) org heading in specified `:file', with nested
headings represented as table rows.

If `:digest' is t, a single table with all entries is generated instead.

`:query' defines what entries to retrieve from org file and add to table.
It should have one of the following forms:

 - plist: om-dash `SIMPLE-QUERY', e.g. (:todo-depth 2 :done-depth 1)
 - list: `ORG-QL' sexp query, e.g. (todo “SOMEDAY“)
 - string: `ORG-QL' string query, e.g. “todo:SOMEDAY“

`SIMPLE-QUERY' format is a convenient way to build queries for some typical
use cases.  The query should be a `plist' with the following properties:

| property     | default | description                                          |
|--------------+---------+------------------------------------------------------|
| :todo-depth  | 2       | nesting level for “todo“ entries                     |
| :done-depth  | 1       | nesting level for “done“ entries                     |
| :category    | nil     | include only entries with any of given category(ies) |
| :no-category | nil     | exclide entries with any of given category(ies)      |
| :priority    | nil     | include only entries with any of given priority(ies) |
| :no-priority | nil     | exclide entries with any of given priority(ies)      |
| :tag         | nil     | include only entries with any of given tag(s)        |
| :every-tag   | nil     | include only entries with all of given tag(s)        |
| :no-tag      | nil     | exclide entries with any of given tag(s)             |
| :blocked     | any     | whether to include blocked entries                   |
| :habit       | any     | whether to include habit entries                     |

Properties `:todo-depth' and `:done-depth' limit how deep the tree is
traversed for top-level headings in “todo“ and “done“ states.

For example:

 - if `:todo-depth' is 0, then level-1 headings in “todo“ state are not
   shown at all

 - if `:todo-depth' is 1, then level-1 headings in “todo“ state are shown
   “collapsed“, i.e. org heading is generated, but without table

 - if `:todo-depth' is 2, then level-1 headings in “todo“ state are shown
   and each has a table with its level-2 children

 - if `:todo-depth' is 3, then level-1 headings in “todo“ state are shown
   and each has a table with its level-2 and level-3 children

...and so on.  Same applies to `:done-depth' parameter.

Whether a keyword is considered as “todo“ or “done“ is defined by
variables `om-dash-todo-keywords' and `om-dash-done-keywords'.
By default they are automatically populated from `org-todo-keywords-1'
and `org-done-keywords', but you can set them to your own values.

`:category', `:priority', and `:tag' properties, as well as their `:no-xxx'
counterparts, can be either a string (to match one value) or a list of strings
\(to match any value from the list).

Examples:
  :priority “A“
  :no-tag (“wip“ “stuck“)

`:every-tag' is similar to `:tag', but it matches entries that have all of
the tags from the list, instead of any tag from list.

`:blocked' and `:habit' properties should be one of the three symbols: `any'
\(ignore type), `yes' (include only entries of this type), `no' (exclude entries).

For `ORG-QL' sexp and string queries, see here:
https://github.com/alphapapa/org-ql?tab=readme-ov-file#queries

`:headline' parameter defines text for org headings which contains
tables.  If `:digest' is t, there is only one table and `:headline'
is just a string.  Otherwise, there are many tables, and `:headline'
is a format string where `%s' can be used for entry title."
  ;; expand template
  (setq params
        (om-dash--prepare-params params))
  ;; parse params
  (let* ((file (or (plist-get params :file) (user-error "Om-dash: missing :file")))
         (file-path (expand-file-name file))
         (file-name (file-name-nondirectory file))
         (query (cond
                 ;; :query given
                 ((when-let ((query (plist-get params :query)))
                    query))
                 ;; :todo or :done given (backwards compatibility)
                 ((let ((todo-depth (plist-get params :todo))
                        (done-depth (plist-get params :done)))
                    (when (or todo-depth done-depth)
                      (warn (s-concat "om-dash: :todo and :done are deprecated,"
                                      " use :query (:todo-depth N :done-depth K)"))
                      `(:todo-depth ,todo-depth :done-depth ,done-depth))))
                 ;; nothing given (default query)
                 (t '(:todo-depth nil :done-depth nil))))
         (digest (plist-get params :digest))
         (table-columns (or (om-dash--plist-obsolete params :columns :table-columns)
                            om-dash-orgfile-columns))
         (forced-keyword (plist-get params :keyword))
         (headline (plist-get params :headline))
         (heading-level (or (plist-get params :heading-level)
                            (om-dash--choose-level))))
    ;; parse and run query
    (let* ((sexp-query (pcase query
                         ;; user provided kwlist, build org-ql sexp query from it
                         ((pred om-dash--kwlistp) (om-dash--orgfile-build-query query))
                         ;; user provided org-ql sexp query
                         ((pred listp) query)
                         ;; user provided org-ql string string, parse it to sexp
                         ((pred stringp) (org-ql--query-string-to-sexp query))
                         (_ (user-error "Om-dash: bad :query %S" query))))
           (entries
            (om-dash--orgfile-run-query file-path sexp-query digest))
           (column-names
            (seq-map (lambda (col)
                       (pcase col
                         (`:state "state")
                         ((or `:title `:title-link) '("title" . t))
                         (`:tags "tags")
                         (_ (user-error "Om-dash: unknown table column %S" col))))
                     table-columns))
           table)
      ;; without :digest, there is a table per top-level entry, and each
      ;; table gets a caption
      (when digest
        (om-dash--insert-heading (or forced-keyword
                                     (om-dash--choose-keyword (length entries)))
                                 (if headline
                                     headline
                                   (format "org tasks (%s)" file-name))
                                 heading-level))
      (dolist (entry entries)
        (let* ((level (org-element-property :level entry))
               (keyword (org-element-property :todo-keyword entry))
               (leveled-keyword (om-dash--orgfile-leveled-keyword keyword level))
               (title (s-trim (car (org-element-property :title entry))))
               (leveled-title (om-dash--orgfile-leveled-title title level))
               (line-number (with-current-buffer (org-element-property :buffer entry)
                              (goto-char (org-element-property :begin entry))
                              (line-number-at-pos)))
               (url (format "%s::%s" file-path line-number))
               (tags (om-dash--format-tags
                      (org-element-property :tags entry))))
          (cond
           ((eq level 1)
            (when table
              (om-dash--insert-table column-names (nreverse table) heading-level)
              (setq table nil))
            (let ((entry-keyword (or forced-keyword keyword))
                  (entry-headline (if headline
                                      (format headline title)
                                    (format "%s (%s)" title file-name))))
              (om-dash--insert-heading entry-keyword entry-headline heading-level)
              (om-dash--insert-caption entry-keyword entry-headline)))
           (t
            (push
             (seq-map (lambda (col)
                        (pcase col
                          (`:state (make-om-dash--cell :text leveled-keyword))
                          (`:title (make-om-dash--cell :text leveled-title))
                          (`:title-link (make-om-dash--cell :text leveled-title :link url))
                          (`:tags (make-om-dash--cell :text tags))
                          (_ (user-error "Om-dash: unknown table column %S" col))))
                      table-columns)
             table)))))
      (when table
        (om-dash--insert-table column-names (nreverse table) heading-level))
      (om-dash--remove-empty-line))))

(defun om-dash--imap-folder-stats (host port machine user password stream auth folder)
  "Connect to IMAP server and read stats for a folder tree."
  (let ((parent-folder (if (s-present-p folder)
                           (downcase folder)
                         nil))
        folder-stats)
    (unless (and (s-present-p user)
                 (s-present-p password))
      (om-dash--log (format "reading imap credentials from ~/.authinfo for machine \"%s\""
                            machine))
      (let* ((machine (if (s-present-p machine)
                          machine
                        host))
             (credentials (auth-source-user-and-password machine)))
        (unless credentials
          (error "Om-dash: machine %s not found in ~/.authinfo" machine))
        (unless (s-present-p user)
          (setq user (nth 0 credentials)))
        (unless (s-present-p password)
          (setq password (nth 1 credentials)))))
    (om-dash--log
     (format "connecting to imap server: server \"%s:%s\" user \"%s\" stream \"%s\" auth \"%s\""
             host port user stream auth))
    (with-current-buffer (or (imap-open host port stream auth)
                             (error "Om-dash: imap connection failed"))
      (imap-authenticate user password)
      (dolist (folder (imap-mailbox-list (s-concat parent-folder "*")))
        (when (or (not parent-folder)
                  (s-equals-p parent-folder folder)
                  (s-starts-with-p (s-concat parent-folder "/") folder))
          (om-dash--log (format "inspecting imap folder %s"
                                folder))
          (imap-mailbox-select folder)
          (let* ((total-count (length (imap-search "ALL")))
                 (new-count (length (imap-search "NEW")))
                 (unread-count (length (imap-search "UNSEEN")))
                 (state (cond ((> new-count 0) "NEW")
                              ((> unread-count 0) "UNREAD")
                              (t "CLEAN"))))
            (push (list :folder folder
                        :state state
                        :total total-count
                        :new new-count
                        :unread unread-count)
                  folder-stats)))))
    (sort folder-stats
          (lambda (a b)
            (s-less-p (plist-get a :folder)
                      (plist-get b :folder))))))

(defun om-dash--imap-server-prop (params key)
  "Get property from :server or om-dash-imap-default-server."
  (or
   ;; block parameter
   (plist-get (plist-get params :server) key)
   ;; block parameter - old name
   (when-let ((value (plist-get params key)))
     (warn "om-dash: %S is deprecated, use :server instead." key)
     value)
   ;; variable
   (plist-get om-dash-imap-default-server key)
   ;; variable - old name
   (when-let* ((name (s-concat "om-dash-imap-" (substring (symbol-name key) 1)))
               (value (symbol-value (intern name))))
     (warn "om-dash: %s is deprecated, use om-dash-imap-default-server instead."
           name)
     value)))

;;;###autoload
(defun org-dblock-write:om-dash-imap (params)
  "Builds org heading with a table of IMAP folder(s) and their unread mail counters.

Usage example:
  #+BEGIN: om-dash-imap :folder “foo/bar“
  ...
  #+END:

Custom config:
  #+BEGIN: om-dash-imap :folder “foo/bar“ :server (:host “example.com“ :user “john“ :password “secret“)
  ...
  #+END:

| parameter      | default                       | description                       |
|----------------+-------------------------------+-----------------------------------|
| :server        | `om-dash-imap-default-server' | server connection config          |
| :columns       | `om-dash-imap-columns'        | list of columns to display        |
| :keyword       | auto                          | keyword of OM_DASH_HEADING        |
| :headline      | auto                          | caption of multi-table blocks     |
| :heading-level | auto                          | unused                            |

`:server' defines IMAP connection parameters.  It must be a `plist' which can have
the following properties:

| property  | default                            | description                 |
|-----------+------------------------------------+-----------------------------|
| :host     | required                           | IMAP server hostmame        |
| :port     | auto                               | IMAP server port            |
| :machine  | same as `:host'                    | machine name in ~/.authinfo |
| :user     | match in ~/.authinfo by `:machine' | IMAP username               |
| :password | match in ~/.authinfo by `:machine' | IMAP password               |
| :stream   | auto                               | STREAM arg for `imap-open'  |
| :auth     | auto                               | AUTH arg for `imap-open'    |

If you omit `:server', or some of the properties, their values are substituted with
the corresponding fields from `om-dash-imap-default-server', when present.

`:host' and `:port' define IMAP server address.
Host must be always set, either via `:server' or `om-dash-imap-default-server'.
Port is optional, default value depends on `:auth' method.

`:user' and `:password' define IMAP credentials.
If not set, `om-dash-imap' will find them in ~/.authinfo by matching by `:machine'
property.  If `:machine' isn't set, `:host' value is used for matching.

`:stream' and `:auth' may be used to force `imap-open' to use specific
connection and authentification types.  For example, you can use `network'
and `login' values to force plain-text unencrypted password."
  ;; expand template
  (setq params
        (om-dash--prepare-params params))
  ;; parse params
  (let* ((host (or (om-dash--imap-server-prop params :host)
                   (user-error
                    "Om-dash: missing :host in :server or om-dash-imap-default-server")))
         (port (om-dash--imap-server-prop params :port))
         (machine (om-dash--imap-server-prop params :machine))
         (user (om-dash--imap-server-prop params :user))
         (password (om-dash--imap-server-prop params :password))
         (stream (om-dash--imap-server-prop params :stream))
         (auth (om-dash--imap-server-prop params :auth))
         (folder (or (plist-get params :folder)
                     (user-error "Om-dash: missing :folder")))
         (table-columns (or (om-dash--plist-obsolete params :columns :table-columns)
                            om-dash-imap-columns))
         (keyword (plist-get params :keyword))
         (headline (or (plist-get params :headline)
                       (format "emails (%s)" folder)))
         (heading-level (or (plist-get params :heading-level)
                            (om-dash--choose-level))))
    ;; get stats and format table
    (let* ((column-names
            (seq-map (lambda (col)
                       (pcase col
                         (:state "state")
                         (:new "new")
                         (:unread "unread")
                         (:total "total")
                         (:folder "folder")
                         (_ (user-error "Om-dash: unknown table column %S" col))))
                     table-columns))
           (entries
            (om-dash--imap-folder-stats host port machine user password stream auth folder))
           (todo-p
            (< 0 (seq-count (lambda (entry)
                              (not (string= (plist-get entry :state)
                                            "CLEAN")))
                            entries)))
           table)
      (dolist (entry entries)
        (let* ((state (plist-get entry :state))
               (new (plist-get entry :new))
               (unread (plist-get entry :unread))
               (total (plist-get entry :total))
               (folder (plist-get entry :folder)))
          (when (or om-dash-imap-empty-folders
                    (> total 0))
            (push
             (seq-map (lambda (col)
                        (pcase col
                          (:state (make-om-dash--cell :text state))
                          (:new (make-om-dash--cell :text (number-to-string new)))
                          (:unread (make-om-dash--cell :text (number-to-string unread)))
                          (:total (make-om-dash--cell :text (number-to-string total)))
                          (:folder (make-om-dash--cell :text folder))
                          (_ (user-error "Om-dash: unknown table column %S" col))))
                      table-columns)
             table))))
      (om-dash--insert-heading (or keyword
                                   (om-dash--choose-keyword todo-p))
                               headline
                               heading-level)
      (when table
        (om-dash--insert-table column-names (nreverse table) heading-level))
      (om-dash--remove-empty-line))))

;;;###autoload
(defun org-dblock-write:om-dash-command (params)
  "Builds org heading with a table from output of a shell command.

Usage example:
  #+BEGIN: om-dash-command :command “curl -s https://api.github.com/users/octocat/repos“ :format json :columns (“name“ “forks_count“)
  ...
  #+END:

| parameter      | default  | description                             |
|----------------+----------+-----------------------------------------|
| :command       | required | shell command to run                    |
| :columns       | required | column names (list of strings)          |
| :format        | `json'   | command output format (`json' or `csv') |
| :keyword       | auto     | keyword of OM_DASH_HEADING              |
| :headline      | auto     | caption of multi-table blocks           |
| :heading-level | auto     | unused                                  |

If `:format' is `json', command output should be a JSON array of
JSON objects, which have a value for every key from `:columns'.

If `:format' is `csv', command output should be CSV.  First column
of CSV becomes value of first column from `:columns', and so on.

Note: using CSV format requires installing `parse-csv' package
from https://github.com/mrc/el-csv"
  ;; expand template
  (setq params
        (om-dash--prepare-params params))
  ;; parse params
  (let* ((command (or (plist-get params :command)
                      (user-error "Om-dash: missing :command")))
         (format (or (plist-get params :format) 'json))
         (columns (or (plist-get params :columns)
                      (user-error "Om-dash: missing :columns")))
         (keyword (plist-get params :keyword))
         (headline (or (plist-get params :headline)
                       (file-name-nondirectory
                        (car (split-string-shell-command command)))))
         (heading-level (or (plist-get params :heading-level)
                            (om-dash--choose-level))))
    ;; run command
    (let* ((raw-output (om-dash--shell-run command t))
           (table (pcase format
                    (`json (om-dash--parse-json columns raw-output))
                    (`csv (om-dash--parse-csv columns raw-output))
                    (_ (user-error "Om-dash: bad :format %S" format))))
           (is-todo (om-dash--table-todo-p table)))
      (om-dash--insert-heading (or keyword
                                   (om-dash--choose-keyword is-todo))
                               headline heading-level)
      (when table
        (om-dash--insert-table columns table heading-level))
      (om-dash--remove-empty-line))))

;;;###autoload
(defun org-dblock-write:om-dash-function (params)
  "Builds org heading with a table from output of a elisp function.

Usage example:
  #+BEGIN: om-dash-function :func example-func
  ...
  #+END:

| parameter      | default  | description                       |
|----------------+----------+-----------------------------------|
| :func          | required | elisp function to call            |
| :args          | nil      | optional function arguments       |
| :columns       | nil      | list of columns to display        |
| :keyword       | nil      | keyword of OM_DASH_HEADING        |
| :headline      | nil      | caption of multi-table blocks     |
| :heading-level | nil      | unused                            |

The function should return a list of tables, where each table is
a `plist' with the following properties:

| property       | default  | description                                          |
|----------------+----------+------------------------------------------------------|
| :columns       | required | list of column names (strings)                       |
| :data          | required | list of rows, where row is a list of cells (strings) |
| :keyword       | “TODO“   | keyword of OM_DASH_HEADING                           |
| :headline      | auto     | caption of multi-table blocks                        |
| :heading-level | auto     | unused                                               |

Every property returned from function, except `:data', may be overwritten by a block
parameter with the same name, if it is provided.

Example function that returns a single 2x2 table:

  (defun example-func ()
    ;; list of tables
    (list
     ;; table plist
     (list :columns `(“foo“ “bar“)
           :data `((“a“ “b“)
                   (“c“ “d“))
           :keyword “TODO“
           :headline “example table“)))"
  ;; expand template
  (setq params
        (om-dash--prepare-params params))
  ;; parse params
  (let* ((function (or (plist-get params :func)
                       (user-error "Om-dash: missing :func")))
         (args (plist-get params :args))
         (forced-columns (plist-get params :columns))
         (default-keyword (om-dash--choose-keyword nil))
         (forced-keyword (plist-get params :keyword))
         (forced-headline (plist-get params :headline))
         (forced-level (plist-get params :heading-level)))
    ;; run function and build table
    (let* ((tables (apply function args))
           (multiple (> (length tables) 1)))
      (dolist (table-plist tables)
        (let* ((column-names (or forced-columns
                                 (om-dash--plist-obsolete table-plist :columns :column-names)
                                 (user-error "Om-dash: missing :columns")))
               (rows (or (om-dash--plist-obsolete table-plist :data :rows)
                         (user-error "Om-dash: missing :data")))
               (keyword (or forced-keyword
                            (plist-get table-plist :keyword)
                            default-keyword))
               (headline (or forced-headline
                             (plist-get table-plist :headline)
                             (symbol-name function)))
               (heading-level (or forced-level
                                  (om-dash--plist-obsolete table-plist :heading-level :level)
                                  (om-dash--choose-level)))
               table)
          (dolist (row rows)
            (push
             (seq-map (lambda (cell-text)
                        (if-let ((link (om-dash--parse-link cell-text)))
                            (make-om-dash--cell :text (car link) :link (cdr link))
                          (make-om-dash--cell :text cell-text)))
                      row)
             table))
          (om-dash--insert-heading keyword
                                   headline
                                   heading-level)
          (when multiple
            (om-dash--insert-caption keyword headline))
          (when table
            (om-dash--insert-table column-names (nreverse table) heading-level))))
      (om-dash--remove-empty-line))))

(defun om-dash--gh-call (&rest args)
  "Run gh with ARGS (no shell), return stdout or signal `user-error'.
Stderr is kept separately (so that stdout can be parsed), and is
included in the error message if gh fails."
  (om-dash--log (s-join " " (cons "gh" (seq-map #'om-dash--shell-quote args))))
  (let ((stderr-file (make-temp-file "om-dash-stderr-")))
    (unwind-protect
        (with-temp-buffer
          (let ((status (apply #'call-process "gh" nil (list t stderr-file) nil args)))
            (unless (eq status 0)
              (user-error "Om-dash: gh failed: %s"
                          (s-trim (concat (with-temp-buffer
                                            (insert-file-contents stderr-file)
                                            (buffer-string))
                                          " "
                                          (buffer-string)))))
            (buffer-string)))
      (delete-file stderr-file))))

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

(defun om-dash--block-params (name)
  "Return effective parameters of the enclosing dynamic block NAME, or nil.
Same as what the block itself uses: drawer parameters of enclosing
headings, overridden by inline “#+BEGIN:“ parameters, with expanded
template.  Point must be inside the block."
  (when-let ((inline (om-dash--dblock-params name)))
    (om-dash--expand-template
     (om-dash--merge-drawer-params name inline))))

(defun om-dash--github-project-item (url number owner status-field)
  "Find project item for topic URL in v2 project NUMBER owned by OWNER.
Returns alist with keys `item-id', `project-id', `field-id', and
`options' (list of (NAME . OPTION-ID)) for single-select STATUS-FIELD."
  (let* ((project-fields
          (format (s-concat
                   "project { id number title "
                   "owner { ... on User { login } ... on Organization { login } } "
                   "field(name: \"%s\") { ... on ProjectV2SingleSelectField "
                   "{ id options { id name } } } }")
                  (om-dash--gh-quote-arg status-field)))
         ;; draft issues have no url of their own; om-dash puts item node id
         ;; into url fragment, e.g. “...?pane=issue&itemId=1#om-dash-item=PVTI_x“
         (item-id (when (string-match "#om-dash-item=\\([^&#]+\\)" url)
                    (match-string 1 url)))
         (json (json-parse-string
                (if item-id
                    (om-dash--gh-call
                     "api" "graphql"
                     "-f" (s-concat "query="
                                    (format (s-concat "query($id: ID!) { node(id: $id) { "
                                                      "... on ProjectV2Item { id %s } } }")
                                            project-fields))
                     "-f" (s-concat "id=" item-id))
                  (om-dash--gh-call
                   "api" "graphql"
                   "-f" (s-concat "query="
                                  (let ((item-fields
                                         (format "projectItems(first: 50) { nodes { id %s } }"
                                                 project-fields)))
                                    (format (s-concat "query($url: URI!) { resource(url: $url) { "
                                                      "... on Issue { %s } "
                                                      "... on PullRequest { %s } } }")
                                            item-fields item-fields)))
                   "-f" (s-concat "url=" url)))
                :object-type 'alist :array-type 'list :null-object nil))
         (nodes (if item-id
                    (delq nil (list (let-alist json .data.node)))
                  (let-alist json .data.resource.projectItems.nodes)))
         (item (or (seq-find
                    (lambda (node)
                      (let-alist node
                        (and (equal .project.number number)
                             (or (not owner)
                                 (string= owner "@me")
                                 (equal .project.owner.login owner)))))
                    nodes)
                   (user-error "Om-dash: %s is not in project %s" url number)))
         (field (or (let-alist item .project.field)
                    (user-error "Om-dash: project has no single-select field %S"
                                status-field))))
    (list (cons 'item-id (alist-get 'id item))
          (cons 'project-id (let-alist item .project.id))
          (cons 'field-id (alist-get 'id field))
          (cons 'options (seq-map (lambda (opt)
                                    (cons (alist-get 'name opt)
                                          (alist-get 'id opt)))
                                  (alist-get 'options field))))))

;;;###autoload
(defun om-dash-github-set-project-status (&optional status)
  "Set v2 project status of the issue or pull request on the current row.

Point must be on a row of a table generated by `om-dash-github' block.
The topic is taken from the first link on the row (e.g. :number or
:title-link column).  The project is taken from `:project' and `:owner'
\(or owner part of `:repo') parameters of the enclosing block, given
inline or in “OM_DASH_GITHUB“ / “OM_DASH“ properties of enclosing
headings; if there is no `:project', you are prompted for the number.

The field to change is `:project-status-field' block parameter, or
`om-dash-github-project-status-field' (default “Status“).  It must be
a single-select field.  STATUS is the option name; when called
interactively, it is read with completion from the field's options.

After the change, the enclosing block is regenerated.

Requires “project“ token scope:

  gh auth refresh -s project"
  (interactive)
  (let* ((url (or (om-dash--row-link)
                  (user-error "Om-dash: no link on this line")))
         (params (or (om-dash--block-params "om-dash-github")
                     (user-error "Om-dash: not inside om-dash-github block")))
         (_ (when (eq (plist-get params :project-type) 'classic)
              (user-error "Om-dash: classic projects are not supported")))
         (number (or (plist-get params :project)
                     (read-number "Project number: ")))
         (owner (or (plist-get params :owner)
                    (when-let ((repo (plist-get params :repo)))
                      (car (s-split "/" repo)))))
         (status-field (or (plist-get params :project-status-field)
                           om-dash-github-project-status-field))
         (item (om-dash--github-project-item url number owner status-field))
         (options (alist-get 'options item))
         (status (or status
                     (completing-read (format "%s: " status-field)
                                      (seq-map #'car options) nil t)))
         (option-id (or (cdr (assoc status options))
                        (user-error "Om-dash: unknown %s option %S"
                                    status-field status))))
    (om-dash--gh-call "project" "item-edit"
                      "--id" (alist-get 'item-id item)
                      "--project-id" (alist-get 'project-id item)
                      "--field-id" (alist-get 'field-id item)
                      "--single-select-option-id" option-id)
    (message "Om-dash: %s set to %s" status-field status)
    ;; note: `org-dblock-update' finds the block by searching for
    ;;       "#+BEGIN:", so it works from inside the table, even when
    ;;       the block contains org headings
    (save-excursion
      (org-dblock-update))))

(defcustom om-dash-github-confirm-changes t
  "If non-nil, ask for confirmation before creating, closing or reopening topics."
  :package-version '(om-dash . "0.7")
  :group 'om-dash
  :type 'boolean)

(defun om-dash--github-row-topic ()
  "Return (KIND . URL) for topic on current row; KIND is “issue“ or “pr“."
  (let ((url (or (om-dash--row-link)
                 (user-error "Om-dash: no link on this line"))))
    (cons (cond ((string-match-p "#om-dash-item=" url)
                 (user-error
                  "Om-dash: draft issues can't be closed or reopened; convert to issue first"))
                ((string-match-p "/pull/[0-9]+" url) "pr")
                ((string-match-p "/issues/[0-9]+" url) "issue")
                (t (user-error "Om-dash: not a github issue or pull request: %s"
                               url)))
          url)))

(defun om-dash--github-refresh-block ()
  "Regenerate enclosing om-dash-github block, if point is inside one."
  (when (om-dash--dblock-params "om-dash-github")
    (save-excursion
      (org-dblock-update))))

(defun om-dash--github-confirm (action url)
  "Ask confirmation for ACTION on URL, if enabled."
  (or (not om-dash-github-confirm-changes)
      (y-or-n-p (format "%s %s? " action url))
      (user-error "Om-dash: cancelled")))

;;;###autoload
(defun om-dash-github-close-topic (&optional arg)
  "Close the issue or pull request on the current row.

The topic is taken from the first link on the row of a table generated
by `om-dash-github' block, and the block is regenerated afterwards.

With prefix ARG, ask for close reason (issues only: “completed“,
“not planned“, or “duplicate“) and an optional comment."
  (interactive "P")
  (pcase-let* ((`(,kind . ,url) (om-dash--github-row-topic))
               (reason (when (and arg (string= kind "issue"))
                         (completing-read "Reason: " '("completed" "not planned" "duplicate")
                                          nil t nil nil "completed")))
               (duplicate-of (when (equal reason "duplicate")
                               (read-string "Duplicate of (number or URL): ")))
               (comment (when arg
                          (read-string "Comment (empty for none): "))))
    (om-dash--github-confirm "Close" url)
    (apply #'om-dash--gh-call kind "close" url
           (append (cond ((s-present-p duplicate-of)
                          (list "--duplicate-of" duplicate-of))
                         (reason
                          (list "--reason" reason)))
                   (when (s-present-p comment) (list "--comment" comment))))
    (message "Om-dash: closed %s" url)
    (om-dash--github-refresh-block)))

;;;###autoload
(defun om-dash-github-reopen-topic (&optional arg)
  "Reopen the issue or pull request on the current row.

The topic is taken from the first link on the row of a table generated
by `om-dash-github' block, and the block is regenerated afterwards.

With prefix ARG, ask for an optional comment."
  (interactive "P")
  (pcase-let* ((`(,kind . ,url) (om-dash--github-row-topic))
               (comment (when arg
                          (read-string "Comment (empty for none): "))))
    (om-dash--github-confirm "Reopen" url)
    (apply #'om-dash--gh-call kind "reopen" url
           (when (s-present-p comment) (list "--comment" comment)))
    (message "Om-dash: reopened %s" url)
    (om-dash--github-refresh-block)))

;;;###autoload
(defun om-dash-github-toggle-topic-state (&optional arg)
  "Close the topic on the current row if it's open, reopen it if it's closed.
Current state is queried from github.  Merged pull requests can't be
reopened.  Prefix ARG is passed to `om-dash-github-close-topic' or
`om-dash-github-reopen-topic'."
  (interactive "P")
  (pcase-let* ((`(,kind . ,url) (om-dash--github-row-topic))
               (state (s-trim (om-dash--gh-call kind "view" url
                                                "--json" "state"
                                                "--jq" ".state"))))
    (pcase state
      ("OPEN" (om-dash-github-close-topic arg))
      ("CLOSED" (om-dash-github-reopen-topic arg))
      ("MERGED" (user-error "Om-dash: %s is merged and can't be reopened" url))
      (_ (user-error "Om-dash: unknown state %S of %s" state url)))))

;;; Editing buffer (C-c C-c to submit, C-c C-k to cancel)

(defvar-local om-dash--edit-callback nil
  "Function called with buffer text when editing is submitted.")

(defvar-local om-dash--edit-window-config nil
  "Window configuration to restore when editing is finished.")

(defun om-dash-edit-submit ()
  "Submit text of the om-dash editing buffer."
  (interactive)
  (let ((callback om-dash--edit-callback)
        (config om-dash--edit-window-config)
        (text (buffer-substring-no-properties (point-min) (point-max))))
    (kill-buffer)
    (when config
      (set-window-configuration config))
    (funcall callback text)))

(defun om-dash-edit-cancel ()
  "Cancel editing in the om-dash editing buffer."
  (interactive)
  (let ((config om-dash--edit-window-config))
    (kill-buffer)
    (when config
      (set-window-configuration config))
    (message "Om-dash: cancelled")))

(defvar om-dash-edit-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'om-dash-edit-submit)
    (define-key map (kbd "C-c C-k") #'om-dash-edit-cancel)
    map)
  "Keymap for `om-dash-edit-mode'.")

(define-minor-mode om-dash-edit-mode
  "Minor mode for om-dash editing buffers.
\\<om-dash-edit-mode-map>\\[om-dash-edit-submit] submits, \\[om-dash-edit-cancel] cancels."
  :lighter " OM-Edit"
  :keymap om-dash-edit-mode-map)

(defun om-dash--edit-text (description initial callback)
  "Pop up a buffer to edit text, then call CALLBACK with the result.
DESCRIPTION is shown in the header line, INITIAL is initial text.
Uses `markdown-mode' if available (github bodies are markdown)."
  (let ((config (current-window-configuration))
        (buffer (generate-new-buffer "*om-dash-edit*")))
    (with-current-buffer buffer
      (if (fboundp 'markdown-mode)
          (markdown-mode)
        (text-mode))
      (insert (or initial ""))
      (goto-char (point-min))
      (om-dash-edit-mode 1)
      (setq om-dash--edit-callback callback
            om-dash--edit-window-config config
            header-line-format
            (substitute-command-keys
             (format "%s  \\<om-dash-edit-mode-map>(\\[om-dash-edit-submit] submit, \\[om-dash-edit-cancel] cancel)"
                     description))))
    (pop-to-buffer buffer)))

;;; Reading table rows

(defun om-dash--table-split-line (line)
  "Split table LINE into list of trimmed cell texts (links -> descriptions)."
  (seq-map (lambda (cell)
             (s-trim (org-link-display-format cell)))
           (butlast (cdr (split-string line "|")))))

(defun om-dash--table-header ()
  "Return list of header names of the table at point."
  (save-excursion
    (goto-char (org-table-begin))
    (while (and (org-at-table-p) (org-at-table-hline-p))
      (forward-line 1))
    (om-dash--table-split-line
     (buffer-substring-no-properties (line-beginning-position)
                                     (line-end-position)))))

(defun om-dash--table-row-values ()
  "Return alist of (HEADER . TEXT) for the table row at point."
  (unless (org-at-table-p)
    (user-error "Om-dash: not in a table"))
  (when (org-at-table-hline-p)
    (user-error "Om-dash: not on a table row"))
  (when (save-excursion
          (forward-line -1)
          (and (org-at-table-p) (org-at-table-hline-p)
               (progn (forward-line -1) (not (org-at-table-p)))))
    (user-error "Om-dash: point is on table header, not on a row"))
  (cl-mapcar #'cons
             (om-dash--table-header)
             (om-dash--table-split-line
              (buffer-substring-no-properties (line-beginning-position)
                                              (line-end-position)))))

(defun om-dash--table-column-values (header)
  "Return distinct non-empty values of column HEADER in the table at point."
  (save-excursion
    (let* ((index (seq-position (om-dash--table-header) header))
           (end (org-table-end))
           values)
      (when index
        (goto-char (org-table-begin))
        (while (< (point) end)
          (unless (org-at-table-hline-p)
            (let ((value (nth index (om-dash--table-split-line
                                     (buffer-substring-no-properties
                                      (line-beginning-position)
                                      (line-end-position))))))
              (when (and (s-present-p value) (not (equal value header)))
                (push value values))))
          (forward-line 1)))
      (seq-uniq (nreverse values)))))

(defun om-dash--row-field (values header)
  "Return non-empty value of column HEADER from row VALUES, or nil."
  (let ((value (cdr (assoc header values))))
    (when (s-present-p value)
      value)))

(defun om-dash--split-list (str separators)
  "Split STR by any of SEPARATORS chars; strip “@“ prefixes and blanks.
“@me“ is kept as is, since gh treats it as the current user."
  (when str
    (seq-remove #'s-blank-p
                (seq-map (lambda (item)
                           (let ((item (s-trim item)))
                             (if (equal item "@me")
                                 item
                               (s-chop-prefix "@" item))))
                         (split-string str (format "[%s]" separators))))))

;;; Updating table rows in place

(defun om-dash--table-raw-cells (line)
  "Split table LINE into list of trimmed raw cell texts (links are kept)."
  (seq-map #'s-trim (butlast (cdr (split-string line "|")))))

(defun om-dash--table-update-row (updates)
  "Set cells of the table row at point and realign the table.
UPDATES is an alist of (HEADER . TEXT); cells of other columns, and
columns not present in the table, are left as is."
  (let* ((header (om-dash--table-header))
         (line (buffer-substring-no-properties (line-beginning-position)
                                               (line-end-position)))
         (indent (progn (string-match "\\`[ \t]*" line)
                        (match-string 0 line)))
         (cells (om-dash--table-raw-cells line)))
    (while (< (length cells) (length header))
      (setq cells (append cells (list ""))))
    (setq cells (seq-map-indexed
                 (lambda (cell index)
                   (if-let ((update (assoc (nth index header) updates)))
                       (cdr update)
                     cell))
                 cells))
    (delete-region (line-beginning-position) (line-end-position))
    (insert indent "| " (s-join " | " cells) " |")
    (org-table-align)))

;;; Creating issues and drafts

(defun om-dash--github-block-project (params)
  "Return (OWNER . NUMBER) of v2 project from block PARAMS, or nil."
  (let ((number (plist-get params :project))
        (owner (or (plist-get params :owner)
                   (when-let ((repo (plist-get params :repo)))
                     (car (s-split "/" repo))))))
    (when (and number owner
               (not (eq (plist-get params :project-type) 'classic)))
      (cons owner number))))

(defun om-dash--github-status-field (params)
  "Return name of project status field for block PARAMS."
  (or (plist-get params :project-status-field)
      om-dash-github-project-status-field))

(defun om-dash--github-set-item-status (url number owner status-field status)
  "Set STATUS-FIELD of project item for URL in project NUMBER to STATUS.
URL may be an item reference like “#om-dash-item=PVTI_...“."
  (let* ((item (om-dash--github-project-item url number owner status-field))
         (option-id (or (cdr (assoc status (alist-get 'options item)))
                        (user-error "Om-dash: unknown %s option %S"
                                    status-field status))))
    (om-dash--gh-call "project" "item-edit"
                      "--id" (alist-get 'item-id item)
                      "--project-id" (alist-get 'project-id item)
                      "--field-id" (alist-get 'field-id item)
                      "--single-select-option-id" option-id)))

(defun om-dash--github-choose-repo (params values)
  "Choose repository for a new issue.
Uses “repo“ column of the row VALUES, then `:repo' block parameter,
otherwise asks with completion over repositories found in the table."
  (or (om-dash--row-field values "repo")
      (plist-get params :repo)
      (let ((repo (completing-read "Repository (owner/name): "
                                   (om-dash--table-column-values "repo"))))
        (unless (string-match-p "\\`[^/ ]+/[^/ ]+\\'" repo)
          (user-error "Om-dash: bad repository %S" repo))
        repo)))

(defun om-dash--github-row-context ()
  "Return block params and row values for creating a topic from current row."
  (let ((params (or (om-dash--block-params "om-dash-github")
                    (user-error "Om-dash: not inside om-dash-github block")))
        (values (om-dash--table-row-values)))
    (when (om-dash--row-link)
      (user-error "Om-dash: row already refers to a topic; add a new row"))
    (list params values)))

(defun om-dash--github-with-body (arg description callback)
  "Call CALLBACK with body text: empty, or edited in a buffer if ARG."
  (if arg
      (om-dash--edit-text description "" callback)
    (funcall callback "")))

(defun om-dash--github-user-ids (logins)
  "Return node ids of github users with LOGINS (“@me“ is the current user)."
  (when logins
    (let* ((indexes (number-sequence 0 (1- (length logins))))
           (query (format "query { %s }"
                          (mapconcat
                           (lambda (index)
                             (let ((login (nth index logins)))
                               (if (equal login "@me")
                                   (format "u%d: viewer { id }" index)
                                 (format "u%d: user(login: %s) { id }"
                                         index (om-dash--jq-str login)))))
                           indexes " ")))
           (data (alist-get 'data
                            (json-parse-string
                             (om-dash--gh-call "api" "graphql"
                                               "-f" (s-concat "query=" query))
                             :object-type 'alist :null-object nil))))
      (seq-map (lambda (index)
                 (or (alist-get 'id (alist-get (intern (format "u%d" index)) data))
                     (user-error "Om-dash: unknown github user %S"
                                 (nth index logins))))
               indexes))))

(defun om-dash--github-set-draft-assignees (draft-id logins)
  "Set assignees of draft issue DRAFT-ID (node id of DraftIssue) to LOGINS.
`gh project item-create' and `gh project item-edit' can't set assignees
of drafts, so this uses `updateProjectV2DraftIssue' GraphQL mutation."
  (let ((ids (om-dash--github-user-ids logins)))
    (om-dash--gh-call
     "api" "graphql"
     "-f" (s-concat
           "query="
           (format (s-concat "mutation { updateProjectV2DraftIssue(input: "
                             "{draftIssueId: %s, assigneeIds: [%s]}) "
                             "{ draftIssue { id } } }")
                   (om-dash--jq-str draft-id)
                   (mapconcat #'om-dash--jq-str ids ", "))))))

;;;###autoload
(defun om-dash-github-create-issue (&optional arg)
  "Create github issue from the table row at point.

Type a new row in a table generated by `om-dash-github' block, fill in
cells, and run this command.  Cells are matched by table header:

| header    | used as                                          |
|-----------+--------------------------------------------------|
| title     | issue title (required)                           |
| repo      | repository “owner/name“                          |
| assignee  | assignees, e.g. “@alice,@bob“                    |
| tags      | labels, e.g. “:bug:ui:“ or “bug,ui“              |
| milestone | milestone title                                  |
| status    | project status (only if block has a v2 project)  |

Other cells are ignored.  If there is no “repo“ cell, `:repo' block
parameter is used, or you're asked to choose a repository (with
completion over repositories found in the table).

If the block has a v2 project (`:project' with `:owner' or `:repo'),
the new issue is added to the project, and its status is set from the
“status“ cell.

Github needs some time until a new issue appears in listings, so the
block is not refreshed; instead, the row is filled in with state,
number and title linking to the new issue.  Refresh the block later
to load full data from github.

Without prefix ARG, the issue is created with empty body.  With prefix
ARG, a buffer is opened to write the body first: \\<om-dash-edit-mode-map>\\[om-dash-edit-submit] creates the
issue, \\[om-dash-edit-cancel] cancels."
  (interactive "P")
  (pcase-let* ((`(,params ,values) (om-dash--github-row-context))
               (title (or (om-dash--row-field values "title")
                          (user-error "Om-dash: row has no title")))
               (repo (om-dash--github-choose-repo params values))
               (labels (om-dash--split-list (om-dash--row-field values "tags") ":,"))
               (assignees (om-dash--split-list
                           (om-dash--row-field values "assignee") ", "))
               (milestone (om-dash--row-field values "milestone"))
               (status (om-dash--row-field values "status"))
               (project (om-dash--github-block-project params))
               (marker (point-marker)))
    (om-dash--github-confirm (format "Create issue %S in" title) repo)
    (om-dash--github-with-body
     arg (format "Body of new issue %S (%s)" title repo)
     (lambda (body)
       (with-current-buffer (marker-buffer marker)
         (save-excursion
           (goto-char marker)
           (let* ((output (apply #'om-dash--gh-call
                                 "issue" "create" "-R" repo
                                 "--title" title "--body" body
                                 (append
                                  (mapcan (lambda (label) (list "--label" label))
                                          labels)
                                  (mapcan (lambda (user) (list "--assignee" user))
                                          assignees)
                                  (when milestone (list "--milestone" milestone)))))
                  (url (or (seq-find (lambda (line)
                                       (string-match-p "\\`https://" line))
                                     (reverse (s-lines (s-trim output))))
                           (user-error "Om-dash: can't find issue url in gh output: %s"
                                       output))))
             (when project
               (let ((item-id (s-trim (om-dash--gh-call
                                       "project" "item-add"
                                       (format "%s" (cdr project))
                                       "--owner" (car project)
                                       "--url" url
                                       "--format" "json" "--jq" ".id"))))
                 (when status
                   (om-dash--github-set-item-status
                    (concat "#om-dash-item=" item-id)
                    (cdr project) (car project)
                    (om-dash--github-status-field params) status))))
             ;; github needs some time until new topic appears in listings,
             ;; so instead of refreshing the block (which would drop the
             ;; row), fill the row in place; next refresh loads full data
             (beginning-of-line)
             (om-dash--table-update-row
              (list (cons "state" "OPEN")
                    (cons "no." (org-link-make-string
                                 url (if (string-match "/issues/\\([0-9]+\\)" url)
                                         (format "#%s" (match-string 1 url))
                                       "#")))
                    (cons "title" (org-link-make-string url title))
                    (cons "repo" repo)))
             (message "Om-dash: created %s (refresh block later to load it from github)"
                      url))))))))

;;;###autoload
(defun om-dash-github-create-draft (&optional arg)
  "Create draft issue in v2 project from the table row at point.

Type a new row in a table generated by `om-dash-github' block that has
a v2 project (`:project' with `:owner' or `:repo'), fill in cells, and
run this command.  Cells are matched by table header:

| header   | used as                        |
|----------+--------------------------------|
| title    | draft title (required)         |
| assignee | assignees, e.g. “@me,@alice“   |
| status   | project status                 |

Other cells are ignored (drafts have no repository or labels).
The block is not refreshed (github needs some time until a new item
appears in listings); instead, the row is filled in with state and
title linking to the new draft.  Refresh the block later.

Without prefix ARG, the draft is created with empty body.  With prefix
ARG, a buffer is opened to write the body first: \\<om-dash-edit-mode-map>\\[om-dash-edit-submit] creates the
draft, \\[om-dash-edit-cancel] cancels."
  (interactive "P")
  (pcase-let* ((`(,params ,values) (om-dash--github-row-context))
               (title (or (om-dash--row-field values "title")
                          (user-error "Om-dash: row has no title")))
               (assignees (om-dash--split-list
                           (om-dash--row-field values "assignee") ", "))
               (status (om-dash--row-field values "status"))
               (project (or (om-dash--github-block-project params)
                            (user-error "Om-dash: draft issues need a v2 project (:project)")))
               (marker (point-marker)))
    (om-dash--github-confirm
     (format "Create draft %S in" title)
     (format "project %s/%s" (car project) (cdr project)))
    (om-dash--github-with-body
     arg (format "Body of new draft %S" title)
     (lambda (body)
       (with-current-buffer (marker-buffer marker)
         (save-excursion
           (goto-char marker)
           (let ((item-id (s-trim (om-dash--gh-call
                                   "project" "item-create"
                                   (format "%s" (cdr project))
                                   "--owner" (car project)
                                   "--title" title
                                   "--body" body
                                   "--format" "json" "--jq" ".id"))))
             (when status
               (om-dash--github-set-item-status
                (concat "#om-dash-item=" item-id)
                (cdr project) (car project)
                (om-dash--github-status-field params) status))
             ;; fill the row in place (see `om-dash-github-create-issue');
             ;; link has the same form as links generated for drafts
             (let* ((json (json-parse-string
                           (om-dash--gh-call
                            "api" "graphql"
                            "-f" (s-concat "query=query($id: ID!) { node(id: $id) { "
                                           "... on ProjectV2Item { databaseId "
                                           "project { url } "
                                           "content { ... on DraftIssue { id } } } } }")
                            "-f" (s-concat "id=" item-id))
                           :object-type 'alist :null-object nil))
                    (url (format "%s?pane=issue&itemId=%s#om-dash-item=%s"
                                 (let-alist json .data.node.project.url)
                                 (let-alist json .data.node.databaseId)
                                 item-id)))
               (when assignees
                 (om-dash--github-set-draft-assignees
                  (or (let-alist json .data.node.content.id)
                      (user-error "Om-dash: can't find draft issue of item %s" item-id))
                  assignees))
               (beginning-of-line)
               (om-dash--table-update-row
                (list (cons "state" "DRAFT")
                      (cons "title" (org-link-make-string url title)))))
             (message "Om-dash: created draft %S (refresh block later to load it from github)"
                      title))))))))

;;; Editing issues, pull requests and drafts

(defun om-dash--github-row-target ()
  "Return plist describing the topic on the current row.
Keys: `:kind' (`issue', `pr' or `draft'), `:url', `:repo' (nil for
drafts), and `:item-id' (project item node id, drafts only)."
  (let ((url (or (om-dash--row-link)
                 (user-error "Om-dash: no link on this line"))))
    (cond
     ((string-match "#om-dash-item=\\([^&#]+\\)" url)
      (list :kind 'draft :url url :item-id (match-string 1 url)))
     ((string-match "github\\.com/\\([^/]+/[^/]+\\)/\\(pull\\|issues\\)/[0-9]+" url)
      (list :kind (if (equal (match-string 2 url) "pull") 'pr 'issue)
            :url url
            :repo (match-string 1 url)))
     (t
      (user-error "Om-dash: not a github issue, pull request or draft: %s" url)))))

(defun om-dash--github-gh-kind (target)
  "Return gh subcommand (“issue“ or “pr“) for TARGET."
  (pcase (plist-get target :kind)
    (`issue "issue")
    (`pr "pr")
    (_ (user-error "Om-dash: not supported for draft issues"))))

(defun om-dash--github-draft-info (item-id)
  "Return alist with `id', `title', `body', `assignees' of draft ITEM-ID."
  (let* ((json (json-parse-string
                (om-dash--gh-call
                 "api" "graphql"
                 "-f" (s-concat "query=query($id: ID!) { node(id: $id) { "
                                "... on ProjectV2Item { content { "
                                "... on DraftIssue { id title body "
                                "assignees(first: 20) { nodes { login } } } } } } }")
                 "-f" (s-concat "id=" item-id))
                :object-type 'alist :array-type 'list :null-object nil))
         (draft (or (let-alist json .data.node.content)
                    (user-error "Om-dash: can't find draft issue of item %s" item-id))))
    (list (cons 'id (alist-get 'id draft))
          (cons 'title (alist-get 'title draft))
          (cons 'body (or (alist-get 'body draft) ""))
          (cons 'assignees (seq-map (lambda (user) (alist-get 'login user))
                                    (let-alist draft .assignees.nodes))))))

(defun om-dash--github-set-draft-body (draft-id body)
  "Set BODY of draft issue DRAFT-ID (node id of DraftIssue)."
  (om-dash--gh-call
   "api" "graphql"
   "-f" (s-concat "query=mutation($id: ID!, $body: String!) { "
                  "updateProjectV2DraftIssue(input: {draftIssueId: $id, body: $body}) "
                  "{ draftIssue { id } } }")
   "-f" (s-concat "id=" draft-id)
   "-f" (s-concat "body=" body)))

(defun om-dash--github-viewer-login ()
  "Return login of the current github user."
  (s-trim (om-dash--gh-call "api" "user" "--jq" ".login")))

(defun om-dash--github-read-list (prompt candidates initial)
  "Read a list of strings with completion over CANDIDATES.
INITIAL is the current list, used as initial input."
  (seq-uniq
   (seq-remove #'s-blank-p
               (seq-map #'s-trim
                        (completing-read-multiple
                         prompt candidates nil nil
                         (when initial
                           (concat (s-join "," initial) ",")))))))

(defun om-dash--github-diff-args (current desired add-flag remove-flag)
  "Return gh arguments that turn CURRENT list into DESIRED list."
  (append
   (mapcan (lambda (item) (list add-flag item))
           (seq-difference desired current))
   (mapcan (lambda (item) (list remove-flag item))
           (seq-difference current desired))))

(defun om-dash--github-update-row-cells (marker updates)
  "Update cells of the row at MARKER (see `om-dash--table-update-row')."
  (with-current-buffer (marker-buffer marker)
    (save-excursion
      (goto-char marker)
      (beginning-of-line)
      (when (org-at-table-p)
        (om-dash--table-update-row updates)))))

;;;###autoload
(defun om-dash-github-edit-body ()
  "Edit body of the issue, pull request or draft on the current row.

The current body is loaded into a buffer: \\<om-dash-edit-mode-map>\\[om-dash-edit-submit] saves it to github,
\\[om-dash-edit-cancel] cancels.  The topic is taken from the first link on the row."
  (interactive)
  (let* ((target (om-dash--github-row-target))
         (url (plist-get target :url)))
    (if (eq (plist-get target :kind) 'draft)
        (let* ((draft (om-dash--github-draft-info (plist-get target :item-id))))
          (om-dash--edit-text
           (format "Body of draft %S" (alist-get 'title draft))
           (alist-get 'body draft)
           (lambda (body)
             (om-dash--github-set-draft-body (alist-get 'id draft) body)
             (message "Om-dash: updated body of draft %S" (alist-get 'title draft)))))
      (let* ((kind (om-dash--github-gh-kind target))
             (body (om-dash--gh-call kind "view" url "--json" "body" "--jq" ".body")))
        (om-dash--edit-text
         (format "Body of %s" url)
         ;; jq output ends with a newline that is not part of the body
         (s-chop-suffix "\n" body)
         (lambda (body)
           (let ((file (make-temp-file "om-dash-body-")))
             (unwind-protect
                 (progn
                   (with-temp-file file
                     (insert body))
                   (om-dash--gh-call kind "edit" url "--body-file" file))
               (delete-file file)))
           (message "Om-dash: updated body of %s" url)))))))

;;;###autoload
(defun om-dash-github-edit-labels ()
  "Edit labels of the issue or pull request on the current row.

Labels are read in the minibuffer, starting with the current ones,
with completion over labels of the repository; separate them with
commas.  Labels are added and removed accordingly, and “tags“ cell
of the row is updated (the block is not refreshed).  Draft issues
have no labels."
  (interactive)
  (let* ((target (om-dash--github-row-target))
         (kind (om-dash--github-gh-kind target))
         (url (plist-get target :url))
         (marker (point-marker))
         (current (s-lines (s-trim (om-dash--gh-call kind "view" url "--json" "labels"
                                                     "--jq" ".labels[].name"))))
         (current (seq-remove #'s-blank-p current))
         (available (seq-remove #'s-blank-p
                                (s-lines (om-dash--gh-call "label" "list"
                                                           "-R" (plist-get target :repo)
                                                           "--limit" "500"
                                                           "--json" "name"
                                                           "--jq" ".[].name"))))
         (desired (om-dash--github-read-list "Labels: " available current))
         (args (om-dash--github-diff-args current desired
                                          "--add-label" "--remove-label")))
    (if (not args)
        (message "Om-dash: labels unchanged")
      (apply #'om-dash--gh-call kind "edit" url args)
      (om-dash--github-update-row-cells
       marker (list (cons "tags" (om-dash--format-tags desired))))
      (message "Om-dash: labels of %s: %s" url
               (if desired (s-join ", " desired) "none")))))

;;;###autoload
(defun om-dash-github-edit-assignees ()
  "Edit assignees of the issue, pull request or draft on the current row.

Assignees are read in the minibuffer, starting with the current ones,
with completion over assignable users of the repository (and “@me“);
separate them with commas.  For issues and pull requests, assignees
are added and removed accordingly; for drafts, the whole list is set.
Then “assignee“ cell of the row is updated (the block is not refreshed)."
  (interactive)
  (let* ((target (om-dash--github-row-target))
         (url (plist-get target :url))
         (marker (point-marker))
         (me (om-dash--github-viewer-login))
         (resolve (lambda (logins)
                    (seq-uniq (seq-map (lambda (login)
                                         (if (equal login "@me") me
                                           (s-chop-prefix "@" login)))
                                       logins))))
         desired)
    (if (eq (plist-get target :kind) 'draft)
        (let* ((draft (om-dash--github-draft-info (plist-get target :item-id)))
               (current (alist-get 'assignees draft)))
          (setq desired (funcall resolve
                                 (om-dash--github-read-list
                                  "Assignees: " (cons "@me" current) current)))
          (if (equal (sort (copy-sequence desired) #'string<)
                     (sort (copy-sequence current) #'string<))
              (setq desired 'unchanged)
            (om-dash--github-set-draft-assignees (alist-get 'id draft) desired)))
      (let* ((kind (om-dash--github-gh-kind target))
             (current (seq-remove #'s-blank-p
                                  (s-lines (s-trim
                                            (om-dash--gh-call kind "view" url
                                                              "--json" "assignees"
                                                              "--jq" ".assignees[].login")))))
             (available (seq-remove #'s-blank-p
                                    (s-lines (om-dash--gh-call
                                              "api" "--paginate"
                                              (format "repos/%s/assignees"
                                                      (plist-get target :repo))
                                              "--jq" ".[].login")))))
        (setq desired (funcall resolve
                               (om-dash--github-read-list
                                "Assignees: " (cons "@me" available) current)))
        (if-let ((args (om-dash--github-diff-args current desired
                                                  "--add-assignee" "--remove-assignee")))
            (apply #'om-dash--gh-call kind "edit" url args)
          (setq desired 'unchanged))))
    (if (eq desired 'unchanged)
        (message "Om-dash: assignees unchanged")
      (om-dash--github-update-row-cells
       marker (list (cons "assignee"
                          (s-join "," (seq-map (lambda (login) (format "@%s" login))
                                               desired)))))
      (message "Om-dash: assignees of %s: %s" url
               (if desired (s-join ", " desired) "none")))))

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

(defvar-local om-dash--keyword-regexp ""
  "Matches TODO and DONE keywrods.")

(defconst om-dash--number-regexp
  "#[0-9]+\\|\\[\\[[^] \t\n]+\\]\\[#[0-9]+\\]\\]"
  "Matches github issue or pr number.")

(defconst om-dash--username-regexp
  "@[[:alnum:]_-]+"
  "Matches github username.")

(defconst om-dash--userlist-regexp
  (s-concat om-dash--username-regexp
            "\\(," om-dash--username-regexp "\\)*")
  "Matches list of github usernames.")

(defconst om-dash--tagline-regexp
  "\\(:[[:alnum:]_@#%:]+\\)+:"
  "Matches org tagline.")

(defconst om-dash--text-regexp ".+"
  "Matches other cell text.")

(defconst om-dash--ruler-regexp "|-"
  "Matches table ruler.")

(defconst om-dash--cell-regexp
  "|\\([ \t]*\\([^| \t\n][^|]*[^| \t\n]\\)[ \t]*\\)|"
  "Matches table cell.")

(defconst om-dash--ruler-or-cell-regexp
  (format "\\(%s\\)\\|\\(%s\\)"
          om-dash--ruler-regexp
          om-dash--cell-regexp)
  "Matches table ruler or cell.")

(defun om-dash--rebuild-regexps ()
  "Rebuild font-lock regexps based on user-defined variables."
  (setq-local om-dash--keyword-regexp
              (s-join
               "\\|"
               (seq-map 'regexp-quote
                        (seq-concatenate 'list
                                         (om-dash--todo-keywords)
                                         (om-dash--done-keywords))))))

(defun om-dash--table-start-p ()
  "Check if we're at the very first line of the table."
  (and (org-at-table-p)
       (org-at-table-hline-p)
       (save-excursion
         (forward-line -1)
         (not (org-at-table-p)))))

(defun om-dash--table-field-p ()
  "Check if we're inside table header or cell."
  (and (org-at-table-p)
       (org-table-check-inside-data-field t t)))

(defun om-dash--headp (cached-table-start)
  "Check if we're inside table header.
Assumes that om-dash--table-field-p returned true."
  (if cached-table-start
      ;; don't do expensive checks if we already know
      ;; where last table starts
      (eq (line-number-at-pos)
          (1+ cached-table-start))
    (and (org-table-check-inside-data-field t t)
         (save-excursion
           (forward-line -1)
           (and (org-at-table-hline-p)
                (progn
                  (forward-line -1)
                  (not (org-at-table-p))))))))

(defun om-dash--cellp (regex)
  "Check if we're inside table cell which text matches regexp.
Assumes that om-dash--table-field-p returned true."
  (and (org-table-check-inside-data-field t t)
       (save-excursion
         (re-search-backward "|" (line-beginning-position 0) t)
         (looking-at (s-concat "|\\s-*\\(" regex "\\)\\s-*|")))))

(defun om-dash--fontify (beg end face)
  "Apply face to given region."
  (add-face-text-property beg end face)
  (add-text-properties beg end (list 'font-lock-fontified t)))

(defun om-dash--fontify-tagline (beg end)
  "Apply faces to tags in tagline."
  (save-excursion
    (goto-char beg)
    (while (re-search-forward ":" end t)
      (let ((pos (point)))
        (om-dash--fontify (1- pos) pos 'org-tag)
        (when (< beg (1- pos))
          (let* ((tag (buffer-substring-no-properties beg (1- pos)))
                 (face (org-get-tag-face tag)))
            (om-dash--fontify beg (1- pos) face)))
        (setq beg pos)))))

(defun om-dash--font-lock-hook (limit)
  "Find tables and cells and apply faces."
  (let ((om-dash--status-faces-cache (make-hash-table))
        cached-table-start)
    (while (re-search-forward om-dash--ruler-or-cell-regexp
                              limit t)
      (backward-char 1)
      (cond
       ;; we're looking at the beginning of the table
       ((match-beginning 1)
        (when (om-dash--table-start-p)
          (setq cached-table-start
                (line-number-at-pos))))
       ;; we're looking at a table cell
       ((match-beginning 2)
        (let ;; cell contents (everything inside "| ... |")
            ((cell-beg (match-beginning 3))
             (cell-end (match-end 3))
             ;; cell text (contents with stripped out padding)
             (text-beg (match-beginning 4))
             (text-end (match-end 4))
             (text (match-string 4)))
          (when (om-dash--table-field-p)
            (if (om-dash--headp cached-table-start)
                (progn
                  ;; apply header faces
                  (om-dash--fontify cell-beg cell-end 'om-dash-header-cell)
                  (om-dash--fontify text-beg text-end 'om-dash-header-text))
              (progn
                ;; apply cell faces
                (om-dash--fontify cell-beg cell-end 'om-dash-cell)
                (cond
                 ;; project status (Todo, In Progress, ...)
                 ((om-dash--status-face-p text)
                  (om-dash--fontify text-beg text-end
                                    (om-dash--choose-status-face text)))
                 ;; keyword (TODO, DONE, ...)
                 ((om-dash--cellp om-dash--keyword-regexp)
                  (om-dash--fontify text-beg text-end
                                    (om-dash--choose-face text)))
                 ;; github pr or issue number (#123)
                 ((om-dash--cellp om-dash--number-regexp)
                  (om-dash--fontify text-beg text-end 'om-dash-number))
                 ;; github username list (@abc[,@abc,...])
                 ((om-dash--cellp om-dash--userlist-regexp)
                  (om-dash--fontify text-beg text-end 'om-dash-username))
                 ;; tagline (:tag1:tag2:)
                 ((om-dash--cellp om-dash--tagline-regexp)
                  (om-dash--fontify-tagline text-beg text-end))
                 ;; regular text
                 ((om-dash--cellp om-dash--text-regexp)
                  (om-dash--fontify text-beg text-end 'om-dash-text))))))))))))

(defvar om-dash-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "b") #'org-dblock-update)
    (define-key map (kbd "u") #'om-dash-update-subtree)
    (define-key map (kbd "t") #'om-dash-update-tree)
    (define-key map (kbd "a") #'org-update-all-dblocks)
    (define-key map (kbd "s") #'om-dash-github-set-project-status)
    (define-key map (kbd "c") #'om-dash-github-close-topic)
    (define-key map (kbd "o") #'om-dash-github-reopen-topic)
    (define-key map (kbd "x") #'om-dash-github-toggle-topic-state)
    (define-key map (kbd "n") #'om-dash-github-create-issue)
    (define-key map (kbd "N") #'om-dash-github-create-draft)
    (define-key map (kbd "e") #'om-dash-github-edit-body)
    (define-key map (kbd "l") #'om-dash-github-edit-labels)
    (define-key map (kbd "A") #'om-dash-github-edit-assignees)
    map)
  "Keymap of om-dash commands, bound to `om-dash-mode-prefix-key'.")

(defvar om-dash-mode-map (make-sparse-keymap)
  "Keymap for `om-dash-mode'.
`om-dash-command-map' is bound here under `om-dash-mode-prefix-key'.")

(defun om-dash--set-prefix-key (symbol value)
  "Setter for `om-dash-mode-prefix-key': rebind `om-dash-command-map'."
  (when (and (boundp symbol) (symbol-value symbol))
    (define-key om-dash-mode-map (kbd (symbol-value symbol)) nil))
  (set-default symbol value)
  (when value
    (define-key om-dash-mode-map (kbd value) om-dash-command-map)))

(defcustom om-dash-mode-prefix-key "C-c C-."
  "Prefix key for `om-dash-command-map' in `om-dash-mode'.
A string in `kbd' format, or nil to not bind the prefix.
Set it via `customize' or `setopt' so that the keymap is updated."
  :package-version '(om-dash . "0.7")
  :group 'om-dash
  :type '(choice (string :tag "Key")
                 (const :tag "None" nil))
  :set #'om-dash--set-prefix-key)

;;;###autoload
(define-minor-mode om-dash-mode
  "Om-dash minor mode.

This minor mode for .org files enables additional highlighting inside
org tables generated by om-dash dynamic blocks.

Things that are highlighted:
 - table header and cell (text and background)
 - org mode keywords
 - issue or pull request state, number, author, etc.
 - tags

After editing keywords list, you need to reactivate minor mode for
changes to take effect.

To activate this mode automatically for specific files, you can use
local variables, e.g. add this to the end of the file:

  # Local Variables\x3a
  # eval: (om-dash-mode 1)
  # End:"
  :lighter " OM-Dash"
  :keymap om-dash-mode-map
  (if om-dash-mode
      (progn
        ;; rebuild regexps from user configuration
        (om-dash--rebuild-regexps)
        ;; register font-lock hook
        (font-lock-add-keywords nil '((om-dash--font-lock-hook)) t)
        ;; refontify buffer
        (save-excursion
          (widen)
          (font-lock-flush)))
    ;; unregister font-lock hook
    (font-lock-remove-keywords nil '((om-dash--font-lock-hook)))
    ;; clear local variables
    (setq-local om-dash--keyword-regexp nil)
    ;; refontify buffer
    (save-excursion
      (widen)
      (font-lock-flush))))

(provide 'om-dash)
;;; om-dash.el ends here
