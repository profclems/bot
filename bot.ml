let port =
  try
    "PORT" |> Sys.getenv |> int_of_string
  with
  | Not_found -> 8000

let username = Sys.getenv "USERNAME"
let password = Sys.getenv "PASSWORD"
let credentials = `Basic(username, password)

let gitlab_access_token = Sys.getenv "GITLAB_ACCESS_TOKEN"
let gitlab_header = [ "PRIVATE-TOKEN", gitlab_access_token ]

let github_access_token = Sys.getenv "GITHUB_ACCESS_TOKEN"

let repo_to_push_to = "coq/coq.git"

let project_api_preview_header =
  [ "Accept", "application/vnd.github.inertia-preview+json" ]

let ssh_push = Sys.file_exists "~/bot_rsa"

open Base
open BotComponents.GitHub
open Cohttp
open Cohttp_lwt_unix
open Lwt

let report_status command report code =
  print_string "Command \"";
  print_string command;
  print_string "\" ";
  print_string report;
  print_string " ";
  print_int code;
  print_endline "."

let execute_cmd command =
  Lwt_unix.system command >|= fun status ->
  match status with
  | Unix.WEXITED code ->
     report_status command "exited with status" code;
     if Int.equal code 0 then true else false
  | Unix.WSIGNALED signal ->
     report_status command "was killed by signal number" signal;
     false
  | Unix.WSTOPPED signal ->
     report_status command "was stopped by signal number" signal;
     false

let cd_repo =
  "cd repo"

let git_fetch repo remote_ref =
  "git fetch -q " ^ repo ^ " " ^ remote_ref ^ " && git checkout -q FETCH_HEAD"

let git_pull_ff repo remote_ref =
  "git pull -q --ff-only " ^ repo ^ " " ^ remote_ref

let git_push repo =
  if ssh_push then
    "GIT_SSH_COMMAND='ssh -i ~/bot_rsa -o \"StrictHostKeyChecking=no\"'"
    ^ "git push git@gitlab.com:"
    ^ repo
  else
    "git push https://" ^ username ^ ":" ^ password ^ "@gitlab.com/" ^ repo

let git_force_push repo local_ref remote_branch_name =
  git_push repo ^ " +" ^ local_ref ^ ":refs/heads/" ^ remote_branch_name

let git_delete repo remote_branch_name =
  git_push repo ^ " :refs/heads/" ^ remote_branch_name

let or_true cmd = "( " ^ cmd ^ " || true )"

let remote_branch_name number = "pr-" ^ Int.to_string number

let (|&&) command1 command2 = command1 ^ " && " ^ command2

let print_response (resp, body) =
  let code = resp |> Response.status |> Code.code_of_status in
  print_string "Response code: ";
  print_int code;
  print_newline ();
  if (code < 200 && code > 299) then (
    print_string "Headers: ";
    resp |> Response.headers |> Header.to_string |> print_endline;
    body |> Cohttp_lwt.Body.to_string >|= fun body ->
    print_endline "Body:";
    print_endline body
  )
  else return ()

let headers header_list =
  Header.init ()
  |> (fun headers -> Header.add_list headers header_list)
  |> (fun headers -> Header.add headers "User-Agent" "coqbot")
  |> (fun headers -> Header.add_authorization headers credentials)

let send_request ~body ~uri header_list =
  let headers = headers header_list in
  print_endline "Sending request.";
  Client.post ~body ~headers uri >>= print_response

let add_rebase_label issue_nb =
  let body = Cohttp_lwt.Body.of_string "[ \"needs: rebase\" ]" in
  let uri =
    "https://api.github.com/repos/coq/coq/issues/"
    ^ Int.to_string issue_nb
    ^ "/labels"
    |> (fun url ->
      print_string "URL: ";
      print_endline url;
      url)
    |> Uri.of_string
  in
  send_request ~body ~uri []

let remove_rebase_label issue_nb =
  let headers = headers [] in
  let uri =
    "https://api.github.com/repos/coq/coq/issues/"
    ^ Int.to_string issue_nb
    ^ "/labels/needs%3A rebase"
    |> (fun url ->
      print_string "URL: ";
      print_endline url;
      url)
    |> Uri.of_string
  in
  print_endline "Sending delete request.";
  Client.delete ~headers uri >>= print_response

let update_milestone issue_nb new_milestone =
  let headers = headers [] in
  let uri =
    "https://api.github.com/repos/coq/coq/issues/" ^ Int.to_string issue_nb
    |> (fun url ->
      print_string "URL: ";
      print_endline url;
      url)
    |> Uri.of_string
  in
  let body =
    "{\"milestone\": " ^ new_milestone ^ "}" |> Cohttp_lwt.Body.of_string
  in
  print_endline "Sending patch request.";
  Client.patch ~headers ~body uri >>= print_response

let remove_milestone issue_nb = update_milestone issue_nb "null"

let add_pr_to_column pr_id column_id =
  let body =
    "{\"content_id\":"
    ^ Int.to_string pr_id
    ^ ", \"content_type\": \"PullRequest\"}"
    |> (fun body ->
      print_endline "Body:";
      print_endline body;
      body)
    |> Cohttp_lwt.Body.of_string
  in
  let uri =
    "https://api.github.com/projects/columns/"
    ^ Int.to_string column_id
    ^ "/cards"
    |> (fun url ->
      print_string "URL: ";
      print_endline url;
      url)
    |> Uri.of_string
  in
  send_request ~body ~uri project_api_preview_header

let send_status_check ~commit ~state ~url ~context ~description =
  let body =
    "{\"state\": \""
    ^ state
    ^ "\",\"target_url\":\""
    ^ url
    ^ "\", \"description\": \""
    ^ description
    ^ "\", \"context\": \""
    ^ context
    ^ "\"}"
    |> (fun body ->
      print_endline "Body:";
      print_endline body;
      body)
    |> Cohttp_lwt.Body.of_string
  in
  let uri =
    "https://api.github.com/repos/coq/coq/statuses/"
    ^ commit
    |> (fun url ->
      print_string "URL: ";
      print_endline url;
      url)
    |> Uri.of_string
  in
  send_request ~body ~uri []

let retry_job ~project_id ~build_id =
  let uri =
    "https://gitlab.com/api/v4/projects/"
    ^ Int.to_string project_id
    ^ "/jobs/"
    ^ Int.to_string build_id
    ^ "/retry"
    |> (fun url ->
      print_string "URL: ";
      print_endline url;
      url)
    |> Uri.of_string
  in
  send_request ~body:Cohttp_lwt.Body.empty ~uri gitlab_header

let handle_json action default body =
  try
    let json = Yojson.Basic.from_string body in
    (* print_endline "JSON decoded."; *)
    action json
  with
  | Yojson.Json_error err ->
     prerr_string "Json error: ";
     prerr_endline err;
     default
  | Yojson.Basic.Util.Type_error (err, _) ->
     prerr_string "Json type error: ";
     prerr_endline err;
     default
  | GraphQL_Failure errors ->
     prerr_endline "GraphQL failure:";
     errors |> String.concat |> prerr_endline;
     default

let generic_get relative_uri ?(header_list=[]) ~default json_handler =
  let uri = "https://api.github.com/" ^ relative_uri |> Uri.of_string in
  let headers = headers header_list in
  Client.get ~headers uri
  >>= (fun (response, body) -> Cohttp_lwt.Body.to_string body)
  >|= (handle_json json_handler default)

let get_pull_request_info pr_number =
  pull_request_db_id_and_milestone ~access_token:github_access_token "coq" "coq" pr_number
  >|= (fun (pr_id, milestone) ->
    match Milestone.get_backport_info "coqbot" milestone with
    | None -> None
    | Some bp_info -> Some (pr_id, bp_info)
  )

let get_status_check ~commit ~build_name =
  generic_get
    ("repos/coq/coq/commits/" ^ commit ^ "/statuses")
    ~default:false
    (fun json ->
      let open Yojson.Basic.Util in
      json
      |> to_list
      |> List.exists ~f:(fun json ->
             json |> member "context" |> to_string |> String.equal build_name
           )
    )

let get_cards_in_column column_id =
  generic_get
    ("projects/columns/" ^ Int.to_string column_id ^ "/cards")
    ~header_list:project_api_preview_header
    ~default:[]
    (fun json ->
      let open Yojson.Basic.Util in
      json
      |> to_list
      |> List.filter_map ~f:(fun json ->
             let card_id = json |> member "id" |> to_int in
             let content_url =
               json
               |> member "content_url"
               |> to_string_option
               |> Option.value ~default:""
             in
             let regexp = "https://api.github.com/repos/.*/\\([0-9]*\\)" in
             if string_match ~regexp content_url then
               let pr_number = Str.matched_group 1 content_url in
               Some (pr_number, card_id)
             else
               None
           )
    )

let pull_request_action json =
    let open Yojson.Basic.Util in
    let action = json |> member "action" |> to_string in
    print_string "Action: ";
    print_endline action;
    let json_pr = json |> member "pull_request" in
    let number = json_pr |> member "number" |> to_int in
    print_string "Number: #";
    print_int number;
    print_newline ();
    match action with
    | "opened" | "reopened" | "synchronize" ->
       let pr_head = json_pr |> member "head"
       and pr_base = json_pr |> member "base"
       in
       let pr_base_branch = pr_base |> member "ref" |> to_string
       and pr_base_repo = pr_base |> member "repo" |> member "html_url" |> to_string
       and pr_head_commit = pr_head |> member "sha" |> to_string
       and pr_branch = pr_head |> member "ref" |> to_string
       and pr_repo = pr_head |> member "repo" |> member "html_url" |> to_string
       in
       (fun () ->
         print_endline "Action warrants fetch / push.";
         cd_repo
         |&& git_fetch pr_base_repo pr_base_branch
         |&& git_pull_ff pr_repo pr_branch
         |&& or_true (git_force_push repo_to_push_to pr_head_commit (remote_branch_name number))
         |> execute_cmd >|= (fun ok ->
          if ok then (
            if json_pr
               |> member "labels"
               |> to_list
               |> List.exists ~f:(fun label ->
                      label
                      |> member "name"
                      |> to_string
                      |> String.equal "needs: rebase"
                    )
            then (
              print_endline "Removing the rebase label.";
              remove_rebase_label number
            )
            else return ()
          )
          else (
            print_endline "Adding the rebase label and a failed status check.";
            add_rebase_label number
            <&> send_status_check ~commit:pr_head_commit ~state:"failure"
                  ~url:""
                  ~context:("ci/gitlab/pr-" ^ Int.to_string number)
                  ~description:"Pipeline did not run on GitLab CI because branch is not up-to-date."
          )
        )
       ) |> Lwt.async
    | "closed" ->
       print_endline "Branch will be deleted following PR closing.";
       (fun () ->
         cd_repo
         |&& git_delete repo_to_push_to (remote_branch_name number)
         |> execute_cmd)
       |> Lwt.async;
       if json_pr |> member "merged" |> to_bool |> not then (
         print_endline "PR was closed without getting merged: remove the milestone.";
         (fun () -> remove_milestone number) |> Lwt.async
       )
       (* TODO: if PR was merged in master without a milestone, post an alert *)
    | _ -> ()

let backport_pr number backport_to =
  "./backport-pr.sh " ^ Int.to_string number ^ " " ^ backport_to
  |&& cd_repo
  |&& git_force_push repo_to_push_to "HEAD" ("staging-" ^ backport_to)
  |> execute_cmd

let project_action json =
  let open Yojson.Basic.Util in
  let project_action = json |> member "action" |> to_string in
  let card = json |> member "project_card" in
  let content_url = card |> member "content_url" |> to_string in
  let regexp =
    "https://api.github.com/repos/[^/]*/[^/]*/issues/\\([0-9]*\\)"
  in
  if
    String.equal project_action "deleted"
    && string_match ~regexp content_url
  then (
    let issue_number = Str.matched_group 1 content_url |> Int.of_string in
    print_string "Issue or PR #";
    print_int issue_number;
    print_endline " was removed from project column:";
    let project_col = card |> member "column_url" |> to_string in
    print_endline project_col;
    (fun () ->
      get_pull_request_info issue_number >>=
        (function
         | None ->
            print_endline "Could not find backporting info for PR.";
            return ()
         | Some (_, {request_inclusion_column; rejected_milestone})
           when 
             "https://api.github.com/projects/columns/"
             ^ Int.to_string request_inclusion_column
             |> String.equal project_col
           ->
            print_endline "This was a request inclusion column: PR was rejected.";
            print_endline "Change of milestone requested to:";
            print_endline rejected_milestone;
            update_milestone issue_number rejected_milestone
         | _ ->
            print_endline "This was not a request inclusion column: ignoring.";
            return ()
        )
    ) |> Lwt.async
  )

let push_action json =
  print_endline "Merge and backport commit messages:";
  let open Yojson.Basic.Util in
  let base_ref = json |> member "ref" |> to_string in
  let commit_action commit =
    let commit_msg = commit |> member "message" |> to_string in
    if string_match ~regexp:"Merge PR #\\([0-9]*\\):" commit_msg then (
      print_endline commit_msg;
      let pr_number = Str.matched_group 1 commit_msg |> Int.of_string in
      print_string "PR #";
      print_int pr_number;
      print_endline " was merged.";
      get_pull_request_info pr_number >>= (fun pr_info ->
        match pr_info with
        | Some (pr_id, {backport_to; request_inclusion_column; backported_column}) ->
           if ("refs/heads/" ^ backport_to |> String.equal base_ref) then (
             print_endline "PR was merged into the backportig branch directly.";
             add_pr_to_column pr_id backported_column
           )
           else (
             print_string "Backporting to ";
             print_string backport_to;
             print_endline " was requested.";
             Lwt.async (fun () -> backport_pr pr_number backport_to);
             add_pr_to_column pr_id request_inclusion_column
           )
        | None ->
           print_endline "Did not get any backporting info.";
           return ()
      )
    )
    else if string_match ~regexp:"Backport PR #\\([0-9]*\\):" commit_msg then (
      print_endline commit_msg;
      let pr_number = Str.matched_group 1 commit_msg in
      print_string "PR #";
      print_string pr_number;
      print_endline " was backported.";
      backported_pr_info
        ~access_token:github_access_token (Int.of_string pr_number) base_ref
      >>= (function
           | Some ({card_id; column_id} as input) ->
              print_string "Moving card ";
              print_string card_id;
              print_string " to column ";
              print_string column_id;
              print_newline ();
              BotComponents.GitHub.mv_card_to_column
                ~access_token:github_access_token input
           | None ->
              prerr_endline "Could not find backporting info for backported PR.";
              return ()
          )
    )
    else return ()
  in
  (fun () ->
    json |> member "commits" |> to_list |> Lwt_list.iter_s commit_action
  ) |> Lwt.async

let get_build_trace ~project_id ~build_id =
  let uri =
    "https://gitlab.com/api/v4/projects/" ^ Int.to_string project_id
    ^ "/jobs/" ^ Int.to_string build_id ^ "/trace"
    |> Uri.of_string
  in
  let headers = headers gitlab_header in
  Client.get ~headers uri
  >>= (fun (_response, body) -> Cohttp_lwt.Body.to_string body)

let repeat_request request =
  let rec aux t =
    request >>= (fun body ->
      if String.is_empty body then
        Lwt_unix.sleep t >>= (fun () -> aux (t *. 2.))
      else
        return body)
  in
  aux 2.

type build_failure = Warn | Retry | Ignore

let trace_action trace =
  let trace_size = String.length trace in
  print_string "Trace size: ";
  print_int trace_size;
  print_newline ();
  let test regexp = string_match ~regexp trace in
  if test "Job failed: exit code 137" then (
    print_endline "Exit code 137. Retrying...";
    Retry
  )
  else if test "Job failed: exit status 255" then (
    print_endline "Exit status 255. Retrying...";
    Retry
  )
  else if test "Job failed (system failure)" then (
    print_endline "System failure. Retrying...";
    Retry
  )
  else if (test "Uploading artifacts to coordinator... failed"
           || test "Uploading artifacts to coordinator... error")
          && not (test "Uploading artifacts to coordinator... ok")
  then (
    print_endline "Artifact uploading failure. Retrying...";
    Retry
  )
  else if (test "transfer closed with outstanding read data remaining"
           || test "HTTP request sent, awaiting response... 500 Internal Server Error"
           || test "The remote end hung up unexpectedly")
  then (
    print_endline "Connectivity issue. Retrying...";
    Retry
  )
  else if test "fatal: reference is not a tree" then (
    print_endline "Normal failure: reference is not a tree.";
    Ignore
  )
  else if test "Error response from daemon: manifest for .* not found" then (
    print_endline "Docker image not found. Do not report anything specific.";
    Ignore
  )
  else Warn

let job_action json =
  let open Yojson.Basic.Util in
  let build_status = json |> member "build_status" |> to_string in
  let build_id = json |> member "build_id" |> to_int in
  let build_name = json |> member "build_name" |> to_string in
  let commit = json |> member "sha" |> to_string in
  if String.equal build_status "failed" then (
    let project_id = json |> member "project_id" |> to_int in
    let failure_reason = json |> member "build_failure_reason" |> to_string in
    let allow_fail = json |> member "build_allow_failure" |> to_bool in
    let send_status_check () =
      if allow_fail then (
        print_endline "Job is allowed to fail.";
        return ()
      )
      else (
        print_endline "Pushing a status check...";
        send_status_check ~commit ~state:"failure"
          ~url:("https://gitlab.com/coq/coq/-/jobs/" ^ Int.to_string build_id)
          ~context:build_name
          ~description:(failure_reason ^ " on GitLab CI")
      )
    in
    print_string "Failed job ";
    print_int build_id;
    print_string " of project ";
    print_int project_id;
    print_endline ".";
    print_string "Failure reason: ";
    print_endline failure_reason;
    (fun () ->
      if String.equal failure_reason "runner_system_failure" then (
        print_endline "Runner failure reported by GitLab CI. Retrying...";
        retry_job ~project_id ~build_id
      )
      else if String.equal failure_reason "stuck_or_timeout_failure" then (
        print_endline "Timeout reported by GitLab CI.";
        send_status_check ()
      )
      else if String.equal failure_reason "script_failure" then (
        print_endline "GitLab CI reports a script failure but it could be something else. Checking the trace...";
        repeat_request (get_build_trace ~project_id ~build_id) >|= trace_action >>=
          (function
           | Warn ->
              print_endline "Actual failure.";
              send_status_check ()

           | Retry ->
              retry_job ~project_id ~build_id

           | Ignore ->
              return ()
          )
      )
      else (
        print_endline "Unusual error.";
        send_status_check ()
      )
    )
    |> Lwt.async
  )
  else if String.equal build_status "success"
          && String.equal build_name "doc:refman"
  then (
    print_endline "This is a successful refman build. Pushing a status check with a link...";
    let url =
      "https://coq.gitlab.io/-/coq/-/jobs/" ^ Int.to_string build_id
      ^ "/artifacts/_install_ci/share/doc/coq/sphinx/html/index.html"
    in
    (fun () ->
       url |> Uri.of_string |> Client.get >>= (fun (resp, _) ->
       if resp |> Response.status |> Code.code_of_status |> Int.equal 200 then
         send_status_check ~commit ~state:"success"
           ~url
           ~context:build_name
           ~description:"Link to refman build artifact."
       else (
         print_endline "But we didn't get a 200 code when checking the URL.";
         send_status_check ~commit ~state:"failure"
           ~url:("https://gitlab.com/coq/coq/-/jobs/" ^ Int.to_string build_id)
           ~context:build_name
           ~description:"Link to refman build artifact: not found."
       )
     )
    ) |> Lwt.async
  )
  else if String.equal build_status "success" then (
    (fun () -> get_status_check ~commit ~build_name >>= (fun b ->
       if b then (
         print_endline "There existed a previous status check for this build, we'll override it.";
         send_status_check ~commit ~state:"success"
           ~url:("https://gitlab.com/coq/coq/-/jobs/" ^ Int.to_string build_id)
           ~context:build_name
           ~description:"Test succeeded on GitLab CI after being retried"
       )
       else return ()
     )
    ) |> Lwt.async
  )

let callback _conn req body =
  let body = Cohttp_lwt.Body.to_string body in
  (* print_endline "Request received."; *)
  let handle_request action =
    (fun () -> body >|= handle_json action ()) |> Lwt.async;
    Server.respond_string ~status:`OK ~body:"" ()
  in
  match Uri.path (Request.uri req) with
  | "/project" -> handle_request project_action
  | "/pull_request" -> handle_request pull_request_action
  | "/push" -> handle_request push_action
  | "/job" -> handle_request job_action
  | _ -> Server.respond_not_found ()

let server =
  print_endline "Initializing repository";
  "git config --global user.email \"coqbot@users.noreply.github.com\""
  |&& "git config --global user.name \"coqbot\""
  |&& "mkdir -p repo"
  |&& cd_repo
  |&& "git init"
  |> execute_cmd
  |> Lwt.ignore_result;
  let mode = `TCP (`Port port) in
  Server.create ~mode (Server.make ~callback ())

let () = Lwt_main.run server
