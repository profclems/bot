(* Define GraphQL queries before opening Base *)

module PullRequest_ID_and_Milestone =
[%graphql
{|
  query prInfo($owner: String!, $repo: String!, $number: Int!) {
    repository(owner: $owner,name: $repo) {
      pullRequest(number: $number) {
        id
        databaseId
        milestone {
          title
          description
        }
      }
    }
  }
|}]

module TeamMembership =
[%graphql
{|
  query teamMember($org: String!, $team: String!, $user: String!) {
    organization(login:$org) {
      team(slug:$team) {
        members(query:$user, first:1) {
          nodes { login }
        }
      }
    }
  }
|}]

module PullRequest_Refs =
[%graphql
{|
  query pull_request_info($owner: String!, $repo: String!, $number: Int!) {
    repository(owner: $owner, name:$repo) {
      pullRequest(number: $number) {
        baseRefName
        baseRefOid @bsDecoder(fn: "Yojson.Basic.to_string")
        headRefName
        headRefOid @bsDecoder(fn: "Yojson.Basic.to_string")
        merged
      }
    }
  }
|}]

open Base
open Cohttp
open Cohttp_lwt
open Cohttp_lwt_unix
open Lwt
open Utils

let send_graphql_query ~token query =
  let uri = Uri.of_string "https://api.github.com/graphql" in
  let headers =
    Cohttp.Header.of_list
      [("Authorization", "bearer " ^ token); ("User-Agent", "coqbot")]
  in
  let body =
    `Assoc [("query", `String query#query); ("variables", query#variables)]
  in
  let serialized_body = Yojson.Basic.to_string body in
  Cohttp_lwt_unix.Client.post ~headers ~body:(`String serialized_body) uri
  >>= fun (rsp, body) ->
  Cohttp_lwt.Body.to_string body
  >|= fun body' ->
  match Cohttp.Code.(code_of_status rsp.status |> is_success) with
  | false -> Error body'
  | true -> (
    try Ok (Yojson.Basic.from_string body' |> query#parse) with
    | Yojson.Json_error err -> Error (f "Json error: %s" err)
    | Yojson.Basic.Util.Type_error (err, _) ->
        Error (f "Json type error: %s" err) )

let untyped_graphql_query ~token query variables =
  let body =
    `Assoc [("query", `String query); ("variables", `Assoc variables)]
    |> Yojson.pretty_to_string |> Body.of_string
  in
  let headers = Header.init_with "Authorization" ("token " ^ token) in
  Client.post ~body ~headers (Uri.of_string "https://api.github.com/graphql")
  >>= (fun (resp, body) ->
        Body.to_string body
        >|= fun body -> (resp |> Response.status |> Code.code_of_status, body)
        )
  >|= fun (code, body) ->
  if code < 200 || code > 299 then
    Error
      (f "GraphQL request was not successful. Response code: %d.\n%s" code body)
  else
    try Ok (Yojson.Basic.from_string body) with Yojson.Json_error err ->
      Error (f "Json error: %s while parsing:%s\n" err body)

(* Types and fragments *)

module Milestone = struct
  type t = {title: string; description: string}

  let fragment =
    "fragment milestone on Milestone {\n\
    \         title\n\
    \         description\n\
    \       }"

  let from_json json =
    let open Yojson.Basic.Util in
    { title= json |> member "title" |> to_string
    ; description= json |> member "description" |> to_string }

  type backport_info =
    { backport_to: string
    ; request_inclusion_column: int
    ; backported_column: int
    ; rejected_milestone: string }

  let get_backport_info bot_name description =
    let project_column_regexp =
      "https://github.com/[^/]*/[^/]*/projects/[0-9]+#column-\\([0-9]+\\)"
    in
    let regexp =
      bot_name ^ ": backport to \\([^ ]*\\) (request inclusion column: "
      ^ project_column_regexp ^ "; backported column: " ^ project_column_regexp
      ^ "; move rejected PRs to: "
      ^ "https://github.com/[^/]*/[^/]*/milestone/\\([0-9]+\\)" ^ ")"
    in
    if string_match ~regexp description then
      let backport_to = Str.matched_group 1 description in
      let request_inclusion_column =
        Str.matched_group 2 description |> Int.of_string
      in
      let backported_column =
        Str.matched_group 3 description |> Int.of_string
      in
      let rejected_milestone = Str.matched_group 4 description in
      Some
        { backport_to
        ; request_inclusion_column
        ; backported_column
        ; rejected_milestone }
    else None
end

module ProjectColumn = struct
  type t = {id: string; db_id: int}

  let fragment =
    "fragment projectColumn on ProjectColumn {\n\
    \         id\n\
    \         databaseId\n\
    \       }"

  let from_json json =
    let open Yojson.Basic.Util in
    { id= json |> member "id" |> to_string
    ; db_id= json |> member "databaseId" |> to_int }
end

module ProjectCard = struct
  type t = {id: string; column: ProjectColumn.t; columns: ProjectColumn.t list}

  let fragment =
    "fragment projectCard on ProjectCard {\n\
    \         id\n\
    \         column { ... projectColumn }\n\
    \         project {\n\
    \           columns(first:100) {\n\
    \             nodes { ... projectColumn }\n\
    \           }\n\
    \         }\n\
    \       }" ^ ProjectColumn.fragment

  let from_json json =
    let open Yojson.Basic.Util in
    { id= json |> member "id" |> to_string
    ; column= json |> member "column" |> ProjectColumn.from_json
    ; columns=
        json |> member "project" |> member "columns" |> member "nodes"
        |> to_list
        |> List.map ~f:ProjectColumn.from_json }
end

let pull_request_base_milestone_and_cards ~token owner repo number =
  let query =
    "query prInfo($owner: String!, $repo: String!, $number: Int!) {\n\
    \       repository(owner: $owner,name: $repo) {\n\
    \         pullRequest(number: $number) {\n\
    \           milestone { ... milestone }\n\
    \           projectCards(first:100) {\n\
    \             nodes { ... projectCard }\n\
    \           }\n\
    \         }\n\
    \       }\n\
    \     }" ^ Milestone.fragment ^ ProjectCard.fragment
  in
  let variables =
    [("owner", `String owner); ("repo", `String repo); ("number", `Int number)]
  in
  untyped_graphql_query ~token query variables
  >|= function
  | Ok json ->
      let pr_json =
        let open Yojson.Basic.Util in
        json |> member "data" |> member "repository" |> member "pullRequest"
      in
      let cards =
        let open Yojson.Basic.Util in
        pr_json |> member "projectCards" |> member "nodes" |> to_list
        |> List.map ~f:ProjectCard.from_json
      in
      let milestone =
        let open Yojson.Basic.Util in
        pr_json |> member "milestone" |> Milestone.from_json
      in
      Ok (cards, milestone)
  | Error err -> Error err

type mv_card_to_column_input = {card_id: string; column_id: string}

let backported_pr_info ~token number base_ref =
  pull_request_base_milestone_and_cards ~token "coq" "coq" number
  >|= function
  | Ok (cards, milestone) ->
      let open Option in
      Milestone.get_backport_info "coqbot" milestone.description
      >>= fun {backport_to; request_inclusion_column; backported_column} ->
      if String.equal ("refs/heads/" ^ backport_to) base_ref then
        List.find_map cards ~f:(fun card ->
            if Int.equal request_inclusion_column card.column.db_id then
              List.find_map card.columns ~f:(fun column ->
                  if Int.equal backported_column column.db_id then
                    Some {card_id= card.id; column_id= column.id}
                  else None )
            else None )
      else None
  | Error err ->
      Stdio.printf "Error in backported_pr_info: %s\n" err ;
      None

let get_pull_request_id_and_milestone ~token ~owner ~repo ~number =
  PullRequest_ID_and_Milestone.make ~owner ~repo ~number ()
  |> send_graphql_query ~token
  >|= function
  | Ok result -> (
    match result#repository with
    | Some repo -> (
      match repo#pullRequest with
      | Some pr -> (
        match (pr#databaseId, pr#milestone) with
        | Some db_id, Some milestone -> (
          match milestone#description with
          | Some description -> (
            match Milestone.get_backport_info "coqbot" description with
            | Some bp_info -> Some (pr#id, db_id, bp_info)
            | _ -> None )
          | _ -> None )
        | _ -> None )
      | _ -> None )
    | _ -> None )
  | _ -> None

let team_membership_of_resp ~org ~team ~user resp =
  match resp#organization with
  | None -> Error (f "Organization %s does not exist." org)
  | Some resp -> (
    match resp#team with
    | None -> Error (f "Team @%s/%s does not exist." org team)
    | Some resp -> (
      match (resp#members)#nodes with
      | Some members
        when members
             |> Array.exists ~f:(function
                  | Some member when String.equal member#login user -> true
                  | _ -> false ) ->
          Ok true
      | _ -> Ok false ) )

let get_team_membership ~token ~org ~team ~user =
  TeamMembership.make ~org ~team ~user ()
  |> send_graphql_query ~token
  >|= Result.map_error ~f:(fun err ->
          f "Query get_team_membership failed with %s" err )
  >|= Result.bind ~f:(team_membership_of_resp ~org ~team ~user)

let pull_request_info_of_resp
    ({issue= {owner; repo; number}} as issue : GitHub_subscriptions.issue_info)
    resp : (GitHub_subscriptions.pull_request_info, string) Result.t =
  let repo_url = f "https://github.com/%s/%s" owner repo in
  match resp#repository with
  | None -> Error (f "Unknown repository %s/%s." owner repo)
  | Some repository -> (
    match repository#pullRequest with
    | None -> Error (f "Unknown pull request %s/%s#%d." owner repo number)
    | Some pull_request ->
        Ok
          { issue
          ; base=
              { branch= {repo_url; name= pull_request#baseRefName}
              ; sha= pull_request#baseRefOid }
          ; head=
              { branch= {repo_url; name= pull_request#headRefName}
              ; sha= pull_request#headRefOid }
          ; merged= pull_request#merged } )

let get_pull_request_refs ~token
    ({issue= {owner; repo; number}} as issue : GitHub_subscriptions.issue_info)
    =
  PullRequest_Refs.make ~owner ~repo ~number ()
  |> send_graphql_query ~token
  >|= Result.map_error ~f:(fun err ->
          f "Query pull_request_info failed with %s" err )
  >|= Result.bind ~f:(pull_request_info_of_resp issue)
