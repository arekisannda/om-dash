;;; om-dash-edit.el --- om-dash: buffer for editing text (C-c C-c / C-c C-k) -*- lexical-binding: t -*-

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

;; A pop-up buffer to edit text (e.g. issue body); \[om-dash-edit-submit]
;; submits, \[om-dash-edit-cancel] cancels.

;;; Code:


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

(provide 'om-dash-edit)
;;; om-dash-edit.el ends here
