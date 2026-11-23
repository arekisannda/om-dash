;;; om-dash-github.el --- om-dash: github issues and pull requests block -*- lexical-binding: t -*-

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

;; `om-dash-github' dynamic block: fetching issues and pull requests
;; with gh and jq, by repository or by v2 project, and rendering them.

;;; Code:

(require 'om-dash-core)
(require 'om-dash-table)
(require 'om-dash-forge)
(require 'json)
(require 'seq)
(require 's)
(require 'ts)

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

(defun om-dash--canon-type (type)
  "Map type to canonical form."
  (cond ((eq type 'pr)
         (warn "om-dash: 'pr is deprecated, use 'pullreq instead.")
         'pullreq)
        (t type)))

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
                ((when-let* ((timestamp (om-dash--parse-reltime query)))
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
                                     (when-let* ((expr (om-dash--gh-query-to-jq query)))
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
  (let* ((match-list (if-let* ((param (plist-get params :milestone)))
                         (cond ((listp param) param)
                               ((stringp param) (list param))
                               (t (user-error
                                   "Om-dash: bad :milestone parameter %S" param)))))
         (ignore-list (if-let* ((param (plist-get params :no-milestone)))
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
  (let* ((any-list (if-let* ((param (plist-get params :label)))
                       (cond ((listp param) param)
                             ((stringp param) (list param))
                             (t (user-error
                                 "Om-dash: bad :label parameter %S" param)))))
         (every-list (if-let* ((param (plist-get params :every-label)))
                         (cond ((listp param) param)
                               ((stringp param) (list param))
                               (t (user-error
                                   "Om-dash: bad :every-label parameter %S" param)))))
         (ignore-list (if-let* ((param (plist-get params :no-label)))
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
  (let* ((match-list (if-let* ((param (plist-get params :author)))
                         (cond ((listp param) param)
                               ((stringp param) (list param))
                               (t (user-error
                                   "Om-dash: bad :author parameter %S" param)))))
         (ignore-list (if-let* ((param (plist-get params :no-author)))
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
  (let* ((match-list (if-let* ((param (plist-get params :assignee)))
                         (cond ((listp param) param)
                               ((stringp param) (list param))
                               (t (user-error
                                   "Om-dash: bad :assignee parameter %S" param)))))
         (ignore-list (if-let* ((param (plist-get params :no-assignee)))
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
  (let* ((match-list (if-let* ((param (plist-get params :reviewer)))
                         (cond ((listp param) param)
                               ((stringp param) (list param))
                               (t (user-error
                                   "Om-dash: bad :reviewer parameter %S" param)))))
         (ignore-list (if-let* ((param (plist-get params :no-reviewer)))
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
  (let* ((match-list (if-let* ((param (plist-get params :review-status)))
                         (cond ((listp param) param)
                               ((symbolp param) (list param))
                               (t (user-error
                                   "Om-dash: bad :review-status %S" param)))))
         (ignore-list (if-let* ((param (plist-get params :no-review-status)))
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
         (match-status (if-let* ((param (plist-get params :project-status)))
                           (cond ((listp param) param)
                                 (t (list param)))))
         (ignore-status (if-let* ((param (plist-get params :no-project-status)))
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
  (when-let* ((project-items (cdr (assoc 'projectItems json))))
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
  (when-let* ((project-cards (cdr (assoc 'projectCards json))))
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
    (if-let* ((ts (ts-parse date)))
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

(defun om-dash--github-nested-title (title depth)
  "Format TITLE of a sub-issue at nesting DEPTH (0 for top-level rows)."
  (if (and title (> depth 0))
      (concat (s-repeat (1- depth) om-dash-github-sub-issue-indent)
              om-dash-github-sub-issue-prefix
              title)
    title))

;;;###autoload
(defun org-dblock-write:om-dash-github (params)
  "Builds org heading with a table of github issues or pull requests.

Basic example:

  #+BEGIN: om-dash-github :repo “owner/repo“ :type issue :open “*“ :closed “-1w“
  ...
  #+END:

More complicated query using simple syntax (as `:open' value, other
parameters as in the basic example):

  :open (:milestone “1.2.3“ :label “blocker“ :no-label “triage“)

Same query but by providing github search query and jq selector:

  :open (“milestone:1.2.3 label:blocker“
         “.labels | (.name == \\“triage\\“) | not“)

\(In a block, the whole `:open' value goes on the “#+BEGIN:“ line.)

Items of a v2 project, from any repo (no :repo needed):

  #+BEGIN: om-dash-github :owner “octocat“ :project 7 :type pullreq :open “*“
  ...
  #+END:

Parameters:

  :repo                  GitHub repo in form “<owner>/<repo>“.
                         Required unless `:owner' and `:project' are given.
  :owner                 User, org or “@me“ owning the project.
                         Default: owner part of `:repo'.
  :project               V2 project number (project mode).
                         Default: nil.
  :owner-type            `user' or `org' (skips auto-detection).
                         Default: auto.
  :project-status-field  Project field used as status.
                         Default: `om-dash-github-project-status-field'.
  :type                  Topic type: `issue', `pullreq', or `any'.
                         Required.
  :any                   Query for topics in any state.
                         Default: see below.
  :open                  Query for topics in open state.
                         Default: see below.
  :closed                Query for topics in closed state.
                         Default: see below.
  :sort                  Sort results by field, “-field“ = descending.
                         Default: “createdAt“.
  :group-by              Column to group rows by, e.g. `:repo'.
                         Default: nil.
  :group-order           Group order: `asc', `desc', or `sort'.
                         Default: `asc'.
  :sub-issues            `nest' sub-issues under parent, or `flat'.
                         Default: `nest'.
  :fields                Explicitly specify list of fields.
                         Default: `om-dash-github-fields'.
  :limit                 Limit number of results.
                         Default: `om-dash-github-limit'.
  :columns               List of columns to display.
                         Default: `om-dash-github-columns'.
  :keyword               Keyword of OM_DASH_HEADING.
                         Default: auto.
  :headline              Caption of multi-table blocks.
                         Default: auto.
  :heading-level         Unused.
                         Default: auto.

Parameters `:any', `:open', and `:closed' define `QUERY' for topics in
corresponding states.  You should specify either `:any' or `:open' and/or
`:close'.  Not specifying anything is equavalent to :open “*“.

`QUERY' can have one of the following forms:

 - plist: om-dash `SIMPLE-QUERY', e.g.:
     (:milestone “1.2.3“ :no-author “bob“)

 - string: standard or extended `GITHUB-QUERY', e.g.:
     “milestone:1.2.3“
     “*“
     “-1w“

 - list: two-element list with `GITHUB-QUERY' and `JQ-SELECTOR' strings, e.g.:
     (“milestone:1.2.3“ “.author.login != “bob“)

You can specify different queries for `:open' and `:closed' topics, e.g.
to show all open issues but only recently closed issues, use:

  :open “*“ :closed “-1mo“

Or you can use a single query regardless of topic state:

  :any “-1mo“

`SIMPLE-QUERY' format is a convenient way to build queries for some typical
use cases.  The query should be a `plist' with the following properties:

  :milestone          Include only topics with any of given milestone(s).
  :no-milestone       Exclude topics with any of given milestone(s).
  :label              Include only topics with any of given label(s).
  :every-label        Include only topics with all of given label(s).
  :no-label           Exclude topics with any of given label(s).
  :author             Include only topics with any of given author(s).
  :no-author          Exclude topics with any of given author(s).
  :assignee           Include only topics with any of given assignee(s).
  :no-assignee        Exclude topics with any of given assignee(s).
  :reviewer           Include only topics with any of given reviewer(s).
  :no-reviewer        Exclude topics with any of given reviewer(s).
  :review-status      Include only topics with any of given review
                      status(es).
  :no-review-status   Exclude topics with any of given review status(es).
  :project            Include only topics added to given project.
  :project-type       Choose between v2 and classic project.
  :project-status     Include only topics with any of given project
                      status(es).
  :no-project-status  Exclude topics with any of given project status(es).
  :created-at         Include only topics created within given date range.
  :updated-at         Include only topics updated within given date range.
  :closed-at          Include only topics closed within given date range.
  :merged-at          Include only topics merged within given date range.

All properties are optional (but at least one should be provided).  Multiple
properties are ANDed, e.g. (:author “bob“ :label “bug“) matches topics with
author “bob“ AND label “bug“.  Most properties support list form, in which case
its elements are ORed.  E.g. (:author (“bob“ “alice“) :label “bug“) matches
topics with label “bug“ AND author either “bob“ OR “alice“.

`:milestone', `:label', `:author', `:assignee', and `:reviewer' properties,
as well as their `:no-xxx' counterparts, can be either a string (to match
one value) or a list of strings (to match any value from the list).  Two
special values are supported: “*“ matches if corresponding property
\(e.g. assignee) is non-empty, and “-“ matches if the property unset/empty.

Examples:
  :author “bob“
  :assignee “-“
  :no-label (“refactoring“ “documentation“)

`:every-label' is similar to `:label', but it matches topics that have all of
the labels from the list, instead of any label from list.

`:review-status' property can be a symbol or a list of symbols
\(to match any status from the list).

Supported values:

  undecided   Review not required, not requested, there're no approvals
              or rejects.
  required    Review is required by repo rules.
  requested   Review is explicitly requested.
  commented   Some reviewers commented without approval or rejection.
  approved    All reviewers either approved or commented, and at least
              one approved.
  rejected    Some reviewers requested changes or dismissed review.

Examples:
  :review-status (required requested)
  :review-status approved
  :no-review-status (approved rejected commented)

GitHub review state model is complicated.  These statuses is an attempt to
provide a simplified view of the review state for most common needs.

Note that not all statuses are mutually exclusive, in particular `required' can
co-exist with any status except `undecided', and `commented' can co-exist with
any other status.  You can match multiple statuses by providing a list.

`:project' defines numeric identifier of the `v2' or `classic' github
project (you can see identifier in the url).  By default, `v2' is assumed,
but you can change type using `:project-type' property.

`:project-status' can be a string or a list of strings.  For `v2'
projects, it matches “status“ field of the project item, which corresponds
to column name if board view of the project.  For `classic' projects, it
matches “column“ property of the project card.

Examples:
  :project 5 :project-status “In work“
  :project 2 :project-type classic :project-status (“Backlog“ “On hold“)

`:created-at', `:updated-at', `:closed-at', `:merged-at' can have one of
this forms:
 - “TIMESTAMP“
 - (> “TIMESTAMP“)
 - (>= “TIMESTAMP“)
 - (< “TIMESTAMP“)
 - (<= “TIMESTAMP“)
 - (range “TIMESTAMP“ “TIMESTAMP“)

Supported `TIMESTAMP' formats:

  “2024-02-20“                 Date.
  “2024-02-20T15:59:59Z“       UTC date and time.
  “2024-02-20T15:59:79+00:00“  Date and time with timezone.
  “-10d“                       10 days before today.
  “-10w“                       10 weeks before today.
  “-10mo“                      10 months before today.
  “-10y“                       10 years before today.

Examples:
  :created-at “2024-02-20“
  :updated-at (>= “-3mo“)

`GITHUB-QUERY' is a string using github search syntax, see “Searching
issues and pull requests“ in:
https://docs.github.com/en/search-github

Besides standard syntax, a few extended forms are supported for github
query:

  “*“       Match all topics.
  “-123d“   Match if topic was updated during last 123 days.
  “-123w“   Same, but weeks.
  “-123mo“  Same, but months.
  “-123y“   Same, but years.

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
\(github.com/users/<owner>/projects/<N> or
github.com/orgs/<owner>/projects/<N>), or “@me“ for your own projects.
Requires “read:project“ token scope:

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

By default, github query uses all fields from `om-dash-github-fields',
plus any field from `om-dash-github-auto-enabled-fields' if it's present
in jq selector.  The latter allows to exclude fields that makes queries
slower, when they're not used.  To change this, you can specify `:fields'
parameter explicitly."
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
         (any-filter (if-let* ((param (plist-get params :any)))
                         (cond ((om-dash--kwlistp param)
                                (om-dash--github-build-query params param))
                               ((and (listp param) (eq (length param) 2))
                                param)
                               ((stringp param)
                                (list param nil))
                               (t (user-error "Om-dash: bad :any parameter %S" param)))))
         (open-filter (if-let* ((param (plist-get params :open)))
                          (cond ((om-dash--kwlistp param)
                                 (om-dash--github-build-query params param))
                                ((and (listp param) (eq (length param) 2))
                                 param)
                                ((stringp param)
                                 (list param nil))
                                (t (user-error "Om-dash: bad :open parameter %S" param)))))
         (closed-filter (if-let* ((param (plist-get params :closed)))
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
                       (number (when-let* ((num (cdr (assoc 'number json))))
                                 (format "#%s" num)))
                       (parent (cdr (assoc 'parent json)))
                       (parent-number (when-let* ((num (cdr (assoc 'number parent))))
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
                      (author (when-let* ((login (cdr (assoc 'login
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
                  (om-dash--forge-nest-topics parsed-output)
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

(provide 'om-dash-github)
;;; om-dash-github.el ends here
