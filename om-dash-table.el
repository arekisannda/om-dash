;;; om-dash-table.el --- om-dash: org table generation and editing -*- lexical-binding: t -*-

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

;; Building org tables from cells, and reading or updating rows of
;; generated tables (used by row-based commands).

;;; Code:

(require 'om-dash-core)
(require 'org)
(require 'org-table)
(require 'cl-lib)
(require 'seq)
(require 's)

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

(defconst om-dash--cookie-regexp "\\`<[lrc]?[0-9]*>\\'"
  "Regexp of org column cookie, e.g. “<20>“, “<r>“, “<l10>“.")

(defun om-dash--column-cookies (params columns &optional partial)
  "Return list of org column cookies for COLUMNS, or nil.

Cookies come from `:column-cookies' block parameter in PARAMS, a plist
of column (as in COLUMNS: keyword like `:title', or string for blocks
with named columns) and cookie, e.g. (:title “<30>“ :tags “<10>“).  The
result has one element per column, nil for columns without a cookie.

A column that is not in COLUMNS is an error, unless PARTIAL is non-nil
\(for blocks whose tables have different columns)."
  (when-let* ((spec (plist-get params :column-cookies)))
    (unless (and (proper-list-p spec) (cl-evenp (length spec)))
      (user-error "Om-dash: bad :column-cookies %S (expected (COLUMN \"<N>\" ...))"
                  spec))
    (let ((pairs (seq-partition spec 2)))
      (dolist (pair pairs)
        (unless (or partial (member (car pair) columns))
          (user-error "Om-dash: :column-cookies has %S, which is not in columns %S"
                      (car pair) columns))
        (unless (and (stringp (cadr pair))
                     (string-match-p om-dash--cookie-regexp (cadr pair))
                     (not (equal (cadr pair) "<>")))
          (user-error "Om-dash: bad cookie %S for %S (use e.g. \"<20>\", \"<r>\", \"<l10>\")"
                      (cadr pair) (car pair))))
      (seq-map (lambda (column) (cadr (assoc column pairs))) columns))))

(defun om-dash--table-cookie-row-p (cells)
  "Check if CELLS (texts of a table row) are a row of column cookies."
  (and (seq-some (lambda (cell) (string-match-p om-dash--cookie-regexp cell)) cells)
       (seq-every-p (lambda (cell)
                      (or (s-blank-p cell) (string-match-p om-dash--cookie-regexp cell)))
                    cells)))

(defun om-dash--insert-table (column-names rows level &optional groups cookies)
  "Generate table from column names and list of rows.
If GROUPS is non-nil, it's a list of group keys, one per row; a ruler
is inserted between rows whose group keys differ.
If ROWS is nil, only the header is generated, with all columns.
If COOKIES is non-nil, it's a list of org column cookies (e.g. “<20>“)
or nil, one per column (see `om-dash--column-cookies'); a row with them
is inserted below the column names, above the header ruler (so it's part
of the header), so that org can shrink or align columns
\(e.g. `org-table-toggle-column-width', “#+STARTUP: shrink“)."
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
    ;; (without rows, every column is empty, so keep them all)
    (when (and om-dash-table-squeeze-empty rows)
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
              (when cookies
                (setq cookies (om-dash--remove-nth cookies col-num)))
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
    ;; columns are at least as wide as their cookies (cookies are never
    ;; truncated)
    (seq-do-indexed (lambda (cookie index)
                      (let ((col (elt columns index)))
                        (when (and cookie (> (length cookie) (cdr col)))
                          (setcdr col (length cookie)))))
                    cookies)
    ;; |--------|
    (om-dash--insert-indent level)
    (om-dash--insert-ruler columns)
    ;; | header |
    (om-dash--insert-indent level)
    (om-dash--insert-header columns)
    ;; | <20>   |
    ;; (below column names, above the header ruler: part of the header,
    ;; so names stay the first row of the table)
    (when (seq-some #'identity cookies)
      (om-dash--insert-indent level)
      (om-dash--insert-row columns (seq-map (lambda (cookie)
                                              (make-om-dash--cell :text (or cookie "")))
                                            cookies)))
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
    ;; (also without rows, so that there's a place to insert rows,
    ;; e.g. with `org-table-insert-row')
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
  (let ((cells (om-dash--table-split-line
                (buffer-substring-no-properties (line-beginning-position)
                                                (line-end-position)))))
    (when (om-dash--table-cookie-row-p cells)
      (user-error "Om-dash: point is on the row of column cookies, not on an item"))
    (cl-mapcar #'cons (om-dash--table-header) cells)))

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
              (when (and (s-present-p value)
                         (not (equal value header))
                         ;; skip row of column cookies
                         (not (string-match-p om-dash--cookie-regexp value)))
                (push value values))))
          (forward-line 1)))
      (seq-uniq (nreverse values)))))

(defun om-dash--row-field (values header)
  "Return non-empty value of column HEADER from row VALUES, or nil."
  (let ((value (cdr (assoc header values))))
    (when (s-present-p value)
      value)))

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
                   (if-let* ((update (assoc (nth index header) updates)))
                       (cdr update)
                     cell))
                 cells))
    (delete-region (line-beginning-position) (line-end-position))
    (insert indent "| " (s-join " | " cells) " |")
    (org-table-align)))

(provide 'om-dash-table)
;;; om-dash-table.el ends here
