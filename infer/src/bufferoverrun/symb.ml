(*
 * Copyright (c) 2017-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)
open! IStd
module F = Format

module BoundEnd = struct
  type t = LowerBound | UpperBound [@@deriving compare]

  let neg = function LowerBound -> UpperBound | UpperBound -> LowerBound

  let to_string = function LowerBound -> "lb" | UpperBound -> "ub"
end

module SymbolPath = struct
  type deref_kind = Deref_ArrayIndex | Deref_CPointer [@@deriving compare]

  type partial =
    | Pvar of Pvar.t
    | Deref of deref_kind * partial
    | Field of Typ.Fieldname.t * partial
    | Callsite of {ret_typ: Typ.t; cs: CallSite.t}
  [@@deriving compare]

  type t = Normal of partial | Offset of partial | Length of partial [@@deriving compare]

  let equal = [%compare.equal: t]

  let equal_partial = [%compare.equal: partial]

  let of_pvar pvar = Pvar pvar

  let of_callsite ~ret_typ cs = Callsite {ret_typ; cs}

  let field p fn = Field (fn, p)

  let deref ~deref_kind p = Deref (deref_kind, p)

  let normal p = Normal p

  let offset p = Offset p

  let length p = Length p

  let rec get_pvar = function
    | Pvar pvar ->
        Some pvar
    | Deref (_, partial) | Field (_, partial) ->
        get_pvar partial
    | Callsite _ ->
        None


  let rec pp_partial_paren ~paren fmt = function
    | Pvar pvar ->
        Pvar.pp_value fmt pvar
    | Deref (Deref_ArrayIndex, p) ->
        F.fprintf fmt "%a[*]" (pp_partial_paren ~paren:true) p
    | Deref (Deref_CPointer, p) ->
        if paren then F.fprintf fmt "(" ;
        F.fprintf fmt "*%a" (pp_partial_paren ~paren:false) p ;
        if paren then F.fprintf fmt ")"
    | Field (fn, Deref (Deref_CPointer, p)) ->
        F.fprintf fmt "%a->%s" (pp_partial_paren ~paren:true) p (Typ.Fieldname.to_flat_string fn)
    | Field (fn, p) ->
        F.fprintf fmt "%a.%s" (pp_partial_paren ~paren:true) p (Typ.Fieldname.to_flat_string fn)
    | Callsite {cs} ->
        F.fprintf fmt "%s" (Typ.Procname.to_simplified_string ~withclass:true (CallSite.pname cs))


  let pp_partial = pp_partial_paren ~paren:false

  let pp fmt = function
    | Normal p ->
        pp_partial fmt p
    | Offset p ->
        F.fprintf fmt "%a.offset" pp_partial p
    | Length p ->
        F.fprintf fmt "%a.length" pp_partial p


  let rec represents_multiple_values = function
    (* TODO depending on the result, the call might represent multiple values *)
    | Callsite _ | Pvar _ ->
        false
    | Deref (Deref_ArrayIndex, _) ->
        true
    | Deref (Deref_CPointer, p)
    (* unsound but avoids many FPs for non-array pointers *)
    | Field (_, p) ->
        represents_multiple_values p


  let rec represents_callsite_sound_partial = function
    | Callsite _ ->
        true
    | Pvar _ ->
        false
    | Deref (_, p) | Field (_, p) ->
        represents_callsite_sound_partial p


  let pp_mark ~markup = if markup then MarkupFormatter.wrap_monospaced pp else pp
end

module Symbol = struct
  type extra_bool = bool

  let compare_extra_bool _ _ = 0

  type t = {unsigned: extra_bool; path: SymbolPath.t; bound_end: BoundEnd.t} [@@deriving compare]

  let compare x y =
    let r = compare x y in
    if Int.equal r 0 then assert (Bool.equal x.unsigned y.unsigned) ;
    r


  type 'res eval = t -> 'res AbstractDomain.Types.bottom_lifted

  let equal = [%compare.equal: t]

  let paths_equal s1 s2 = SymbolPath.equal s1.path s2.path

  let make : unsigned:bool -> SymbolPath.t -> BoundEnd.t -> t =
   fun ~unsigned path bound_end -> {unsigned; path; bound_end}


  let pp : F.formatter -> t -> unit =
   fun fmt s ->
    SymbolPath.pp fmt s.path ;
    if Config.developer_mode then Format.fprintf fmt ".%s" (BoundEnd.to_string s.bound_end) ;
    if Config.bo_debug > 1 then F.fprintf fmt "(%c)" (if s.unsigned then 'u' else 's')


  let pp_mark ~markup = if markup then MarkupFormatter.wrap_monospaced pp else pp

  let is_unsigned {unsigned} = unsigned

  let path {path} = path

  let bound_end {bound_end} = bound_end
end

module SymbolSet = struct
  include PrettyPrintable.MakePPSet (Symbol)

  let union3 x y z = union (union x y) z
end

module SymbolMap = struct
  include PrettyPrintable.MakePPMap (Symbol)

  let for_all2 : f:(key -> 'a option -> 'b option -> bool) -> 'a t -> 'b t -> bool =
   fun ~f x y ->
    match merge (fun k x y -> if f k x y then None else raise Exit) x y with
    | _ ->
        true
    | exception Exit ->
        false
end
