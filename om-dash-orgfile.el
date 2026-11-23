;;; om-dash-orgfile.el --- om-dash: org file block -*- lexical-binding: t -*-

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

;; `om-dash-orgfile' dynamic block: tables with entries of an org file.

;;; Code:

(require 'om-dash-core)
(require 'om-dash-table)
(require 'org)
(require 'org-element)
(require 'org-ql)
(require 's)
(require 'seq)

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
         (any-category (if-let* ((param (plist-get plist :category)))
                           (cond ((listp param) param)
                                 ((stringp param) (list param))
                                 (t (user-error
                                     "Om-dash: bad :category parameter %S" param)))))
         (no-category (if-let* ((param (plist-get plist :no-category)))
                          (cond ((listp param) param)
                                ((stringp param) (list param))
                                (t (user-error
                                    "Om-dash: bad :no-category parameter %S" param)))))
         (any-priority (if-let* ((param (plist-get plist :priority)))
                           (cond ((listp param) param)
                                 ((stringp param) (list param))
                                 (t (user-error
                                     "Om-dash: bad :priority parameter %S" param)))))
         (no-priority (if-let* ((param (plist-get plist :no-priority)))
                          (cond ((listp param) param)
                                ((stringp param) (list param))
                                (t (user-error
                                    "Om-dash: bad :no-priority parameter %S" param)))))
         (any-tag (if-let* ((param (plist-get plist :tag)))
                      (cond ((listp param) param)
                            ((stringp param) (list param))
                            (t (user-error
                                "Om-dash: bad :tag parameter %S" param)))))
         (every-tag (if-let* ((param (plist-get plist :every-tag)))
                        (cond ((listp param) param)
                              ((stringp param) (list param))
                              (t (user-error
                                  "Om-dash: bad :every-tag parameter %S" param)))))
         (no-tag (if-let* ((param (plist-get plist :no-tag)))
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

  #+BEGIN: om-dash-orgfile :file “~/my/file.org“
  ...
  #+END:

Custom simple query:

  #+BEGIN: om-dash-orgfile :file “~/my/file.org“ :query (:todo-depth 3)
  ...
  #+END:

Custom org-ql query:

  #+BEGIN: om-dash-orgfile :file “~/my/file.org“ :query (todo “SOMEDAY“)
  ...
  #+END:

Parameters:

  :file           Path to .org file.
                  Required.
  :query          Query for org entries.
                  Default: (:todo-depth 2 :done-depth 1).
  :digest         Generate single table with all entries.
                  Default: nil.
  :columns        List of columns to display.
                  Default: `om-dash-orgfile-columns'.
  :keyword        Keyword of OM_DASH_HEADING.
                  Default: auto.
  :headline       Caption of multi-table blocks.
                  Default: auto.
  :heading-level  Unused.
                  Default: auto.

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

  :todo-depth   Nesting level for “todo“ entries.
                Default: 2.
  :done-depth   Nesting level for “done“ entries.
                Default: 1.
  :category     Include only entries with any of given category(ies).
                Default: nil.
  :no-category  Exclude entries with any of given category(ies).
                Default: nil.
  :priority     Include only entries with any of given priority(ies).
                Default: nil.
  :no-priority  Exclude entries with any of given priority(ies).
                Default: nil.
  :tag          Include only entries with any of given tag(s).
                Default: nil.
  :every-tag    Include only entries with all of given tag(s).
                Default: nil.
  :no-tag       Exclude entries with any of given tag(s).
                Default: nil.
  :blocked      Whether to include blocked entries.
                Default: `any'.
  :habit        Whether to include habit entries.
                Default: `any'.

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

`:blocked' and `:habit' properties should be one of the three symbols:
`any' (ignore type), `yes' (include only entries of this type), `no'
\(exclude entries).

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
                 ((when-let* ((query (plist-get params :query)))
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
      ;; with :digest, the single table is generated even without entries;
      ;; without :digest, a top-level entry without rows stays collapsed
      (when (or table digest)
        (om-dash--insert-table column-names (nreverse table) heading-level))
      (om-dash--remove-empty-line))))

(provide 'om-dash-orgfile)
;;; om-dash-orgfile.el ends here
