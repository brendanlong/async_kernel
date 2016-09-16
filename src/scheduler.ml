open Core_kernel.Std
open Import

module Deferred  = Deferred1
module Scheduler = Scheduler1
module Stream    = Async_stream

include (Scheduler : (module type of Scheduler
                       with module Bvar        := Scheduler.Bvar
                       with module Ivar        := Scheduler.Ivar
                       with module Time_source := Scheduler.Time_source))

let t = Scheduler.t

include Monitor.Exported_for_scheduler

let find_local key =
  Execution_context.find_local (current_execution_context (t ())) key
;;

let with_local key value ~f =
  let t = t () in
  let execution_context =
    Execution_context.with_local (current_execution_context t) key value
  in
  with_execution_context t execution_context ~f
;;

let main_execution_context = (t ()).main_execution_context

let can_run_a_job t = num_pending_jobs t > 0 || Bvar.has_any_waiters t.yield

let has_upcoming_event t = not (Timing_wheel_ns.is_empty (events t))

let next_upcoming_event t = Timing_wheel_ns.next_alarm_fires_at (events t)

let next_upcoming_event_exn t = Timing_wheel_ns.next_alarm_fires_at_exn (events t)

let event_precision t = Timing_wheel_ns.alarm_precision (events t)

let cycle_start t = t.cycle_start

let run_every_cycle_start t ~f =
  t.run_every_cycle_start <- f :: t.run_every_cycle_start;
;;

let map_cycle_times t ~f =
  Stream.create (fun tail ->
    run_every_cycle_start t ~f:(fun () -> Tail.extend tail (f t.last_cycle_time)));
;;

let cycle_num_jobs t =
  Stream.create (fun tail ->
    run_every_cycle_start t ~f:(fun () -> Tail.extend tail t.last_cycle_num_jobs));
;;

let cycle_count t = t.cycle_count

let set_max_num_jobs_per_priority_per_cycle t int =
  t.max_num_jobs_per_priority_per_cycle <-
    Max_num_jobs_per_priority_per_cycle.create_exn int;
;;

let max_num_jobs_per_priority_per_cycle t =
  Max_num_jobs_per_priority_per_cycle.raw t.max_num_jobs_per_priority_per_cycle
;;

let set_thread_safe_external_job_hook t f = t.thread_safe_external_job_hook <- f

let thread_safe_enqueue_external_job t execution_context f a =
  Thread_safe_queue.enqueue t.external_jobs (External_job.T (execution_context, f, a));
  t.thread_safe_external_job_hook ();
;;

let set_event_added_hook t f = t.event_added_hook <- Some f
let set_job_queued_hook  t f = t.job_queued_hook  <- Some f

let create_alarm t f =
  let execution_context = current_execution_context t in
  Gc.Expert.Alarm.create (fun () ->
    thread_safe_enqueue_external_job t execution_context f ());
;;

let add_finalizer t heap_block f =
  let execution_context = current_execution_context t in
  let finalizer heap_block =
    (* Here we can be in any thread, and may not be holding the async lock.  So, we can
       only do thread-safe things.

       By putting [heap_block] in [external_jobs], we are keeping it alive until the next
       time the async scheduler gets around to dequeueing it.  Calling
       [t.thread_safe_external_job_hook] ensures that will happen in short order.  Thus,
       we are not dramatically increasing the lifetime of [heap_block], since the OCaml
       runtime already resurrected [heap_block] so that we could refer to it here.  The
       OCaml runtime already removed the finalizer function when it noticed [heap_block]
       could be finalized, so there is no infinite loop in which we are causing the
       finalizer to run again.  Also, OCaml does not impose any requirement on finalizer
       functions that they need to dispose of the block, so it's fine that we keep
       [heap_block] around until later. *)
    if Debug.finalizers then (Debug.log_string "enqueueing finalizer");
    thread_safe_enqueue_external_job t execution_context f heap_block;
  in
  if Debug.finalizers then (Debug.log_string "adding finalizer");
  (* We use [Caml.Gc.finalise] instead of [Core_kernel.Std.Gc.add_finalizer] because the latter
     has its own wrapper around [Caml.Gc.finalise] to run finalizers synchronously. *)
  Caml.Gc.finalise finalizer heap_block;
;;

let add_finalizer_exn t x f =
  add_finalizer t (Heap_block.create_exn x)
    (fun heap_block -> f (Heap_block.value heap_block))
;;

(** [force_current_cycle_to_end] sets the number of normal jobs allowed to run in this
    cycle to zero.  Thus, after the currently running job completes, the scheduler will
    switch to low priority jobs and then end the current cycle. *)
let force_current_cycle_to_end t =
  Job_queue.set_jobs_left_this_cycle t.normal_priority_jobs 0
;;

let advance_clock t ~now =
  Time_source.advance t.time_source ~to_:now;
  match t.advance_synchronous_wall_clock with
  | None -> ()
  | Some f -> f ~now;
;;

let run_cycle t =
  if debug then (Debug.log "run_cycle starting" t [%sexp_of: t]);
  t.on_start_of_cycle ();
  let now = Time_ns.now () in
  t.cycle_count <- t.cycle_count + 1;
  t.cycle_start <- now;
  Bvar.broadcast t.yield ();
  let num_jobs_run_at_start_of_cycle = num_jobs_run t in
  List.iter t.run_every_cycle_start ~f:(fun f -> f ());
  advance_clock t ~now;
  start_cycle t ~max_num_jobs_per_priority:t.max_num_jobs_per_priority_per_cycle;
  let rec run_jobs () =
    match Scheduler.run_jobs t with
    | Ok () -> ()
    | Error (exn, backtrace) ->
      Monitor.send_exn (Monitor.current ()) exn ~backtrace:(`This backtrace);
      (* [run_jobs] stopped due to an exn.  There may still be jobs that could be run
         this cycle, so [run_jobs] again. *)
      run_jobs ()
  in
  run_jobs ();
  t.last_cycle_time <- Time_ns.diff (Time_ns.now ()) t.cycle_start;
  t.last_cycle_num_jobs <- num_jobs_run t - num_jobs_run_at_start_of_cycle;
  if Bvar.has_any_waiters t.yield_until_no_jobs_remain
  && Job_queue.length t.normal_priority_jobs + Job_queue.length t.low_priority_jobs = 0
  then (Bvar.broadcast t.yield_until_no_jobs_remain ());
  t.on_end_of_cycle ();
  if debug
  then (Debug.log "run_cycle finished"
         (uncaught_exn t, is_some (next_upcoming_event t))
         [%sexp_of: Error.t option * bool]);
;;

let run_cycles_until_no_jobs_remain () =
  if debug then (Debug.log_string "run_cycles_until_no_jobs_remain starting");
  let t = t () in
  if is_dead t
  then (
    raise_s [%message
      "run_cycles_until_no_jobs_remain cannot proceed -- scheduler is dead"
        ~scheduler:(t : t)]);
  let rec loop () =
    run_cycle t;
    advance_clock t ~now:(Time_ns.now ());
    (* We [fire_past_alarms] just before checking if there are pending jobs, so that clock
       events that fire become jobs, and thus cause an additional [loop]. *)
    Time_source.fire_past_alarms t.time_source;
    if can_run_a_job t then (loop ())
  in
  loop ();
  (* Reset the current execution context to maintain the invariant that when we're not in
     a job, [current_execution_context = main_execution_context]. *)
  set_execution_context t t.main_execution_context;
  if debug then (Debug.log_string "run_cycles_until_no_jobs_remain finished");
  Option.iter (uncaught_exn t) ~f:Error.raise;
;;

let make_async_unusable () =
  let t = !t_ref in
  t.check_access <-
    Some (fun () ->
      raise_s [%sexp "Async scheduler is unusable due to [make_async_unusable]"]);
;;

let reset_in_forked_process () =
  if debug then (Debug.log_string "reset_in_forked_process");
  (* There is no need to empty [main_monitor_hole]. *)
  Scheduler.(t_ref := create ());
;;

let check_invariants t = t.check_invariants

let set_check_invariants t b = t.check_invariants <- b

let set_record_backtraces t b = t.record_backtraces <- b

let set_on_start_of_cycle t f = t.on_start_of_cycle <- f
let set_on_end_of_cycle   t f = t.on_end_of_cycle   <- f

let yield t = Bvar.wait t.yield

let yield_until_no_jobs_remain t = Bvar.wait t.yield_until_no_jobs_remain

let yield_every ~n =
  if n <= 0
  then (raise_s [%message "Scheduler.yield_every got nonpositive count" (n : int)])
  else if n = 1
  then (stage (fun t -> yield t))
  else (
    let count_until_yield = ref n in
    stage (fun t ->
      decr count_until_yield;
      if !count_until_yield > 0
      then Deferred.unit
      else (
        count_until_yield := n;
        yield t)))
;;

module Very_low_priority_work = struct
  module Worker_result = Very_low_priority_worker.Exec_result



  let rec run t = run_workers t ~num_execs_before_yielding:1_000
  and run_workers t ~num_execs_before_yielding =
    if num_execs_before_yielding = 0
    then (yield_then_run t)
    else if not (Deque.is_empty t.very_low_priority_workers)
    then (
      let worker = Deque.dequeue_front_exn t.very_low_priority_workers in
      set_execution_context t worker.execution_context;
      run_worker t worker ~num_execs_before_yielding)
  and yield_then_run t =
    if not (Deque.is_empty t.very_low_priority_workers)
    then (Deferred.upon (yield t) (fun () -> run t))
  and run_worker t worker ~num_execs_before_yielding =
    assert (phys_equal t.current_execution_context worker.execution_context);
    if num_execs_before_yielding = 0
    then (
      Deque.enqueue_front t.very_low_priority_workers worker;
      yield_then_run t)
    else (
      let num_execs_before_yielding = num_execs_before_yielding - 1 in
      match worker.exec () with
      | Finished     -> run_workers t        ~num_execs_before_yielding
      | Not_finished -> run_worker  t worker ~num_execs_before_yielding
      | exception exn ->
        let bt = Exn.backtrace () in
        Monitor.send_exn (Monitor.current ()) exn ~backtrace:(`This bt);
        run_workers t ~num_execs_before_yielding)
  ;;

  let enqueue ~f =
    let t = t () in
    let queue = t.very_low_priority_workers in
    let running = not (Deque.is_empty queue) in
    let execution_context =
      Execution_context.create_like
        (current_execution_context t)
        ~priority:Low
    in
    Deque.enqueue_back queue { execution_context; exec = f };
    if not running then (enqueue t execution_context run t)
  ;;
end

let%test_module _ = (module struct

  (* [Monitor.catch_stream]. *)
  let%test_unit _ =
    let d = Stream.next (Monitor.catch_stream (fun () -> raise_s [%message [%here]])) in
    run_cycles_until_no_jobs_remain ();
    assert (is_some (Deferred.peek d))
  ;;

  (* [Monitor.catch]. *)
  let%test_unit _ =
    let d = Monitor.catch (fun () -> raise_s [%message [%here]]) in
    run_cycles_until_no_jobs_remain ();
    assert (is_some (Deferred.peek d))
  ;;

end)
