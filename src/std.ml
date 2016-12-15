module Limiter_in_this_directory = Limiter

open! Core_kernel.Std
open! Import

module Bvar                         = Bvar
module Clock_ns                     = Clock_ns
module Condition                    = Async_condition
module Deferred                     = Deferred
module Eager_deferred               = Eager_deferred
module Execution_context            = Execution_context
module Gc                           = Async_gc
module Handler                      = Handler
module Invariant                    = Async_invariant
module Ivar                         = Ivar
module Quickcheck_intf              = Async_quickcheck_intf
module Quickcheck                   = Async_quickcheck
module Lazy_deferred                = Lazy_deferred
module Limiter                      = Limiter_in_this_directory
module Monad_sequence               = Monad_sequence
module Monitor                      = Monitor
module Mvar                         = Mvar
module Pipe                         = Pipe
module Priority                     = Priority
module Require_explicit_time_source = Require_explicit_time_source
module Sequencer                    = Throttle.Sequencer
module Stream                       = Async_stream
module Synchronous_time_source      = Synchronous_time_source
module Tail                         = Tail
module Throttle                     = Throttle
module Time_source                  = Time_source


let after          = Clock_ns.after
let at             = Clock_ns.at
let catch          = Monitor.catch
let choice         = Deferred.choice
let choose         = Deferred.choose
let don't_wait_for = Deferred.don't_wait_for
let every          = Clock_ns.every
let never          = Deferred.never
let schedule       = Scheduler.schedule
let schedule'      = Scheduler.schedule'
let try_with       = Monitor.try_with
let upon           = Deferred.upon
let with_timeout   = Clock_ns.with_timeout
let within         = Scheduler.within
let within'        = Scheduler.within'

let ( >>>  ) = Deferred.Infix. ( >>> )
let ( >>=? ) = Deferred.Result.( >>= )
let ( >>|? ) = Deferred.Result.( >>| )

include (Deferred : Monad.Infix with type 'a t := 'a Deferred.t)

include Deferred.Let_syntax

(** Intended usage is to [open Use_eager_deferred] to shadow operations from the non-eager
    world and rebind them to their eager counterparts. *)
module Use_eager_deferred = struct
  module Deferred = Eager_deferred
  include (Eager_deferred : Monad.Infix with type 'a t := 'a Deferred.t)
  include Eager_deferred.Let_syntax
  let upon = Eager_deferred.upon
  let ( >>> ) = Eager_deferred.Infix.( >>> )
end

(* This test must be in this library, because it requires [return] to be inlined.  Moving
   it to another library will cause it to break with [X_LIBRARY_INLINING=false]. *)
let%test_unit "[return ()] does not allocate" =
  let w1 = Gc.minor_words () in
  ignore (return () : _ Deferred.t);
  ignore (Deferred.return () : _ Deferred.t);
  ignore (Deferred.Let_syntax.return () : _ Deferred.t);
  ignore (Deferred.Let_syntax.Let_syntax.return () : _ Deferred.t);
  let w2 = Gc.minor_words () in
  [%test_result: int] w2 ~expect:w1;
;;
