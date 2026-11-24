;;; om-dash-mode.el --- om-dash: minor mode with highlighting and key bindings -*- lexical-binding: t -*-

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

;; `om-dash-mode': highlighting of generated tables (keywords, numbers,
;; usernames, tags, project statuses) and `om-dash-command-map'.

;;; Code:

(require 'om-dash-core)
(require 'org)
(require 'org-table)
(require 's)
(require 'seq)

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

(defun om-dash--progress-done-p (marker)
  "Check if progress MARKER (e.g. “{7/7}“ or “{100%}“) is complete.
Markers without numbers (“{/}“, “{%}“) are not complete."
  (cond
   ((string-match "\\`{\\([0-9]+\\)/\\([0-9]+\\)}\\'" marker)
    (let ((done (string-to-number (match-string 1 marker)))
          (total (string-to-number (match-string 2 marker))))
      (and (> total 0) (= done total))))
   ((string-match "\\`{\\([0-9]+\\)%}\\'" marker)
    (= (string-to-number (match-string 1 marker)) 100))))

(defun om-dash--progress-font-lock-hook (limit)
  "Apply faces to progress markers of headings up to LIMIT.
Only headings with “:OM_DASH_HEADING: t“ are fontified (see
`om-dash--heading-progress-p').  Org's faces of statistics cookies
are used: `org-checkbox-statistics-done' when complete, otherwise
`org-checkbox-statistics-todo'."
  (while (re-search-forward om-dash--progress-regexp limit t)
    (let ((beg (match-beginning 0))
          (end (match-end 0))
          (marker (match-string-no-properties 0)))
      (when (save-excursion
              (goto-char beg)
              (and (org-at-heading-p)
                   (om-dash--heading-enabled-p)))
        (om-dash--fontify beg end (if (om-dash--progress-done-p marker)
                                      'org-checkbox-statistics-done
                                    'org-checkbox-statistics-todo)))))
  nil)

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

(defvar om-dash-command-map (make-sparse-keymap)
  "Keymap of om-dash commands, bound to `om-dash-mode-prefix-key'.
Forge commands are added by om-dash-forge-commands.el.  Commands for
updating blocks are not bound here, since org already has keys for
them (e.g. `C-c C-x C-u' for `org-dblock-update').")

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
        ;; register font-lock hooks
        (font-lock-add-keywords nil '((om-dash--font-lock-hook)
                                      (om-dash--progress-font-lock-hook))
                                t)
        ;; refontify buffer
        (save-excursion
          (widen)
          (font-lock-flush)))
    ;; unregister font-lock hooks
    (font-lock-remove-keywords nil '((om-dash--font-lock-hook)
                                     (om-dash--progress-font-lock-hook)))
    ;; clear local variables
    (setq-local om-dash--keyword-regexp nil)
    ;; refontify buffer
    (save-excursion
      (widen)
      (font-lock-flush))))

(provide 'om-dash-mode)
;;; om-dash-mode.el ends here
