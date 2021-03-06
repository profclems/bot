val get_installation_token :
     bot_info:Bot_info.t
  -> key:Mirage_crypto_pk.Rsa.priv
  -> app_id:int
  -> owner:string
  -> repo:string
  -> (string * float, string) result Lwt.t

val get_installations :
     bot_info:Bot_info.t
  -> key:Mirage_crypto_pk.Rsa.priv
  -> app_id:int
  -> (string list, string) result Lwt.t
