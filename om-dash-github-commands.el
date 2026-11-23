;;; om-dash-github-commands.el --- om-dash: commands for github topics in om-dash tables -*- lexical-binding: t -*-

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

;; Commands operating on the topic on the current table row: set
;; project status, close/reopen, create from a new row, edit body,
;; labels and assignees.

;;; Code:

(require 'om-dash-core)
(require 'om-dash-table)
(require 'om-dash-forge)
(require 'om-dash-edit)
(require 'om-dash-github)
(require 'om-dash-mode)
(require 'json)
(require 'let-alist)
(require 'org)
(require 'seq)
(require 's)

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
                    (when-let* ((repo (plist-get params :repo)))
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

;;; Creating issues and drafts

(defun om-dash--github-block-project (params)
  "Return (OWNER . NUMBER) of v2 project from block PARAMS, or nil."
  (let ((number (plist-get params :project))
        (owner (or (plist-get params :owner)
                   (when-let* ((repo (plist-get params :repo)))
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
         (desired (om-dash--forge-read-list "Labels: " available current))
         (args (om-dash--forge-diff-args current desired
                                          "--add-label" "--remove-label")))
    (if (not args)
        (message "Om-dash: labels unchanged")
      (apply #'om-dash--gh-call kind "edit" url args)
      (om-dash--forge-update-row-cells
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
                                 (om-dash--forge-read-list
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
                               (om-dash--forge-read-list
                                "Assignees: " (cons "@me" available) current)))
        (if-let* ((args (om-dash--forge-diff-args current desired
                                                  "--add-assignee" "--remove-assignee")))
            (apply #'om-dash--gh-call kind "edit" url args)
          (setq desired 'unchanged))))
    (if (eq desired 'unchanged)
        (message "Om-dash: assignees unchanged")
      (om-dash--forge-update-row-cells
       marker (list (cons "assignee"
                          (s-join "," (seq-map (lambda (login) (format "@%s" login))
                                               desired)))))
      (message "Om-dash: assignees of %s: %s" url
               (if desired (s-join ", " desired) "none")))))
;;; Key bindings

;; github commands in `om-dash-command-map' (prefix `om-dash-mode-prefix-key')
(define-key om-dash-command-map (kbd "s") #'om-dash-github-set-project-status)
(define-key om-dash-command-map (kbd "c") #'om-dash-github-close-topic)
(define-key om-dash-command-map (kbd "o") #'om-dash-github-reopen-topic)
(define-key om-dash-command-map (kbd "x") #'om-dash-github-toggle-topic-state)
(define-key om-dash-command-map (kbd "n") #'om-dash-github-create-issue)
(define-key om-dash-command-map (kbd "N") #'om-dash-github-create-draft)
(define-key om-dash-command-map (kbd "e") #'om-dash-github-edit-body)
(define-key om-dash-command-map (kbd "l") #'om-dash-github-edit-labels)
(define-key om-dash-command-map (kbd "A") #'om-dash-github-edit-assignees)

(provide 'om-dash-github-commands)
;;; om-dash-github-commands.el ends here
