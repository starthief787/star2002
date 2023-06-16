(** Determines the domain size used for 'wrap proofs'. This can be determined by
    the fixpoint function provided by {!wrap_domains.f_debug}, but for
    efficiently this is disabled in production and uses the hard-coded results.
*)

val domains :
     (module Snarky_backendless.Snark_intf.Run with type field = 'field)
  -> ('a, 'b, 'field) Import.Spec.ETyp.t
  -> ('c, 'd, 'field) Import.Spec.ETyp.t
  -> ('a -> 'c)
  -> Import.Domains.t

val rough_domains : Import.Domains.t
