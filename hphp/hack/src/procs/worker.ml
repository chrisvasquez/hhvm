(**
 * Copyright (c) 2015, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the "hack" directory of this source tree.
 *
 *)

(*****************************************************************************
 * The job executed by the worker.
 *
 * The 'serializer' is the job continuation: it is a function that must
 * be called at the end of the request ir order to send back the result
 * to the master (this is "internal business", this is not visible outside
 * this module). The slave will provide the expected function.
 * cf 'send_result' in 'slave_main'.
 *
 *****************************************************************************)

type request = Request of (serializer -> unit)
and serializer = { send: 'a. 'a -> unit }

type slave_job_status =
  | Slave_terminated of Unix.process_status

let on_slave_cancelled parent_outfd =
  (* The cancelling controller will ignore result of cancelled job anyway (see
   * wait_for_cancel function), so we can send back anything. *)
  Marshal_tools.to_fd_with_preamble parent_outfd "anything"
  |> ignore

(*****************************************************************************
 * Entry point for spawned worker.
 *
 *****************************************************************************)

let slave_main ic oc =
  let start_user_time = ref 0. in
  let start_system_time = ref 0. in
  let start_minor_words = ref 0. in
  let start_promoted_words = ref 0. in
  let start_major_words = ref 0. in
  let start_minor_collections = ref 0 in
  let start_major_collections = ref 0 in

  let infd = Daemon.descr_of_in_channel ic in
  let outfd = Daemon.descr_of_out_channel oc in

  let send_result data =
    let tm = Unix.times () in
    let end_user_time = tm.Unix.tms_utime +. tm.Unix.tms_cutime in
    let end_system_time = tm.Unix.tms_stime +. tm.Unix.tms_cstime in
    let { Gc.
      minor_words = end_minor_words;
      promoted_words = end_promoted_words;
      major_words = end_major_words;
      minor_collections = end_minor_collections;
      major_collections = end_major_collections;
      _;
    } = Gc.quick_stat () in
    Measure.sample "worker_user_time" (end_user_time -. !start_user_time);
    Measure.sample "worker_system_time" (end_system_time -. !start_system_time);
    Measure.sample "minor_words" (end_minor_words -. !start_minor_words);
    Measure.sample "promoted_words" (end_promoted_words -. !start_promoted_words);
    Measure.sample "major_words" (end_major_words -. !start_major_words);
    Measure.sample "minor_collections" (float (end_minor_collections - !start_minor_collections));
    Measure.sample "major_collections" (float (end_major_collections - !start_major_collections));
    let stats = Measure.serialize (Measure.pop_global ()) in
    (* If we got so far, just let it finish "naturally" *)
    SharedMem.set_on_worker_cancelled (fun () -> ());
    let len = Marshal_tools.to_fd_with_preamble ~flags:[Marshal.Closures] outfd (data,stats) in
    if len > 30 * 1024 * 1024 (* 30 MB *) then begin
      Hh_logger.log "WARNING: you are sending quite a lot of data (%d bytes), \
        which may have an adverse performance impact. If you are sending \
        closures, double-check to ensure that they have not captured large
        values in their environment." len;
      Printf.eprintf "%s" (Printexc.raw_backtrace_to_string
        (Printexc.get_callstack 100));
    end
  in

  try
    Measure.push_global ();
    let Request do_process = Marshal_tools.from_fd_with_preamble infd in
    SharedMem.set_on_worker_cancelled (fun () -> on_slave_cancelled outfd);
    let tm = Unix.times () in
    let gc = Gc.quick_stat () in
    start_user_time := tm.Unix.tms_utime +. tm.Unix.tms_cutime;
    start_system_time := tm.Unix.tms_stime +. tm.Unix.tms_cstime;
    start_minor_words := gc.Gc.minor_words;
    start_promoted_words := gc.Gc.promoted_words;
    start_major_words := gc.Gc.major_words;
    start_minor_collections := gc.Gc.minor_collections;
    start_major_collections := gc.Gc.major_collections;
    do_process { send = send_result };
    exit 0
  with
  | End_of_file ->
      exit 1
  | SharedMem.Out_of_shared_memory ->
      Exit_status.(exit Out_of_shared_memory)
  | SharedMem.Hash_table_full ->
      Exit_status.(exit Hash_table_full)
  | SharedMem.Heap_full ->
      Exit_status.(exit Heap_full)
  | SharedMem.Sql_assertion_failure err_num ->
      let exit_code = match err_num with
        | 11 -> Exit_status.Sql_corrupt
        | 14 -> Exit_status.Sql_cantopen
        | 21 -> Exit_status.Sql_misuse
        | _ -> Exit_status.Sql_assertion_failure
      in
      Exit_status.exit exit_code
  | e ->
      let e_str = Printexc.to_string e in
      Printf.printf "Exception: %s\n" e_str;
      EventLogger.log_if_initialized (fun () ->
        EventLogger.worker_exception e_str
      );
      print_endline "Potential backtrace:";
      Printexc.print_backtrace stdout;
      exit 2

let win32_worker_main restore (state, _controller_fd) (ic, oc) =
  restore state;
  slave_main ic oc

let maybe_send_status_to_controller fd status =
  match fd with
  | None ->
    ()
  | Some fd ->
    let to_controller fd msg =
      ignore (Marshal_tools.to_fd_with_preamble fd msg : int)
    in
    match status with
    | Unix.WEXITED 0 ->
      ()
    | Unix.WEXITED 1 ->
      (* 1 is an expected exit code. On unix systems, when the master process exits, the pipe
       * becomes readable. We fork a worker slave, which reads 0 bytes and exits with code 1.
       * In this case, the master is dead so trying to write a message to the master will
       * cause an exception *)
      ()
    | _ ->
      Timeout.with_timeout
        ~timeout:10
        ~on_timeout:(fun _ ->
          Hh_logger.log "Timed out sending status to controller"
        )
        ~do_:(fun _ ->
          to_controller fd (Slave_terminated status)
        )

(**
 * On Windows, the Worker is a process and runs the job directly. See above.
 *
 * On Unix, the Worker is split into a Worker Master and a Worker Slave
 * process with the Master reaping the Slave's process with waitpid.
 * The Slave runs the actual job and sends the results over the oc.
 * If the Slave exits normally (exit code 0), the Master keeps living and
 * waits for the next incoming job before forking a new slave.
 *
 * If the Slave exits with a non-zero code, the Master also exits with the
 * same code. Thus, the owning process of this Worker can just waitpid
 * directly on this process and see correct exit codes.
 *
 * Except `WSIGNALED i` and `WSTOPPED i` are all compressed to `exit 2`
 * and `exit 3` respectively. Thus some resolution is lost. So if
 * the underling Worker Slave is for example SIGKILL'd by the OOM killer,
 * then the owning process won't be aware of it.
 *
 * To regain this lost resolution, controller_fd can be optionally set. The
 * real exit statuses (includinng WSIGNALED and WSTOPPED) will be sent over
 * this file descriptor to the Controller when the Worker Slave exits
 * abnormally (non-zero exit code).
 *)
let unix_worker_main restore (state, controller_fd) (ic, oc) =
  restore state;
  let in_fd = Daemon.descr_of_in_channel ic in
  if !Utils.profile then Utils.log := prerr_endline;
  try
    while true do
      (* Wait for an incoming job : is there something to read?
         But we don't read it yet. It will be read by the forked slave. *)
      let readyl, _, _ = Unix.select [in_fd] [] [] (-1.0) in
      if readyl = [] then exit 0;
      (* We fork a slave for every incoming request.
         And let it die after one request. This is the quickest GC. *)
      match Fork.fork() with
      | 0 -> slave_main ic oc
      | pid ->
          (* Wait for the slave termination... *)
          let status = snd (Sys_utils.waitpid_non_intr [] pid) in
          let () = maybe_send_status_to_controller controller_fd status in
          match status with
          | Unix.WEXITED 0 -> ()
          | Unix.WEXITED 1 ->
              raise End_of_file
          | Unix.WEXITED code ->
              Printf.printf "Worker exited (code: %d)\n" code;
              flush stdout;
              Pervasives.exit code
          | Unix.WSIGNALED x ->
              let sig_str = PrintSignal.string_of_signal x in
              Printf.printf "Worker interrupted with signal: %s\n" sig_str;
              exit 2
          | Unix.WSTOPPED x ->
              Printf.printf "Worker stopped with signal: %d\n" x;
              exit 3
    done;
    assert false
  with End_of_file -> exit 0
