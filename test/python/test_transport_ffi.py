from __future__ import annotations

from pathlib import Path
import json
import os
import signal
import time
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).parents[2]


@unittest.skipUnless(shutil.which("erl") and shutil.which("erlc"), "Erlang toolchain required")
class ErlangTransportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.library = Path(cls.temporary.name) / "successor-1.0.0"
        ebin = cls.library / "ebin"
        python = cls.library / "priv" / "python"
        ebin.mkdir(parents=True)
        python.mkdir(parents=True)
        subprocess.run(
            ["erlc", "-Werror", "-o", str(ebin), str(ROOT / "src" / "successor_python_ffi.erl")],
            check=True, capture_output=True,
        )
        shutil.copy(ROOT / "priv" / "python" / "kernel.py", python)
        shutil.copy(ROOT / "priv" / "python" / "lock.py", python)
        shutil.copytree(ROOT / "priv" / "python" / "successor_tools", python / "successor_tools",
                        ignore=shutil.ignore_patterns("__pycache__"))
        (ebin / "successor.app").write_text(
            '{application, successor, [{vsn,"1.0.0"},{modules,[successor_python_ffi]}]}.'
        )

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def erl(self, expression: str, timeout: float = 10) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(
            ["erl", "-pa", str(self.library / "ebin"), "-noshell", "-eval", expression],
            check=True, capture_output=True, text=True, timeout=timeout,
        )
        return result

    def test_persistence_failure_and_close(self):
        self.erl(r"""
          application:load(successor),
          {ok,K}=successor_python_ffi:start(list_to_binary("/tmp/successor-ffi-basic-"++os:getpid())),
          {ok,{succeeded,<<"42\n">>,false}}=successor_python_ffi:execute(K,<<"a">>,<<"x=40\nx+2">>,1000,1000),
          {ok,{failed,_,false,_}}=successor_python_ffi:execute(K,<<"b">>,<<"raise ValueError('x')">>,1000,1000),
          {ok,{succeeded,<<"40\n">>,false}}=successor_python_ffi:execute(K,<<"c">>,<<"x">>,1000,1000),
          nil=successor_python_ffi:close(K), timer:sleep(50), false=is_process_alive(K), halt().""")


    def test_workspace_lock_refuses_duplicate_and_reacquires_after_close(self):
        self.erl(r"""
          application:load(successor),
          Base="/tmp/successor-ffi-lock-"++os:getpid(),
          Same=list_to_binary(Base), Other=list_to_binary(Base++"-other"),
          {ok,K1}=successor_python_ffi:start(Same),
          {error,<<"python workspace is already active">>}=successor_python_ffi:start(Same),
          {ok,K2}=successor_python_ffi:start(Other),
          nil=successor_python_ffi:close(K1),
          {ok,K3}=successor_python_ffi:start(Same),
          nil=successor_python_ffi:close(K2), nil=successor_python_ffi:close(K3), halt().""")



    def test_bounded_escaped_metadata_does_not_lose_healthy_namespace(self):
        self.erl(r"""
          application:load(successor),
          {ok,K}=successor_python_ffi:start(list_to_binary("/tmp/successor-ffi-metadata-"++os:getpid())),
          Id=binary:copy(<<34>>,4096),
          Source=unicode:characters_to_binary([
            "kept_unicode=True\nraise ValueError('",
            lists:duplicate(10000,16#1F600), "')"]),
          {ok,{failed,<<>>,true,Error}}=successor_python_ffi:execute(K,Id,Source,1000,0),
          true=(byte_size(Error)>16000),
          {ok,{succeeded,<<"True\n">>,false}}=successor_python_ffi:execute(
            K,<<"after">>,<<"kept_unicode">>,1000,1000),
          nil=successor_python_ffi:close(K), halt().""")

    def test_native_oversized_header_is_rejected_without_buffering_to_deadline(self):
        self.erl(r"""
          application:load(successor),
          {ok,K}=successor_python_ffi:start(list_to_binary("/tmp/successor-ffi-raw-"++os:getpid())),
          T=erlang:monotonic_time(millisecond),
          {ok,{unknown,_}}=successor_python_ffi:execute(K,<<"raw">>,
            <<"import os; os.write(1, b'z' * 1000000)">>,300000,1000),
          true=(erlang:monotonic_time(millisecond)-T < 1000),
          timer:sleep(30), false=is_process_alive(K), halt().""")


    def test_native_stderr_is_protocol_contamination_not_host_log_output(self):
        result = self.erl(r"""
          application:load(successor),
          {ok,K}=successor_python_ffi:start(list_to_binary("/tmp/successor-ffi-stderr-"++os:getpid())),
          {ok,{unknown,_}}=successor_python_ffi:execute(K,<<"raw-stderr">>,
            <<"import os; os.write(2, b'z' * 1000000)">>,300000,1000),
          timer:sleep(30), false=is_process_alive(K), halt().""")
        self.assertEqual(result.stderr, "")

    def test_os_pid_queries_cannot_extend_absolute_deadline(self):
        self.erl(r"""
          application:load(successor), Parent=self(),
          {ok,K}=successor_python_ffi:start(list_to_binary("/tmp/successor-ffi-deadline-"++os:getpid())),
          T=erlang:monotonic_time(millisecond),
          spawn(fun()-> Parent!{done,successor_python_ffi:execute(K,<<"slow">>,
            <<"import time; time.sleep(30)">>,40,1000)} end),
          Spam=fun F(0)->ok; F(N)->successor_python_ffi:os_pid(K),F(N-1) end,
          Spam(200),
          receive {done,{ok,{unknown,_}}} -> ok after 1000 -> error(deadline_extended) end,
          true=(erlang:monotonic_time(millisecond)-T < 1000), halt().""")


    def test_maximum_escaped_output_frame_and_plus_one_admission(self):
        self.erl(r"""
          application:load(successor),
          {ok,K}=successor_python_ffi:start(list_to_binary("/tmp/successor-ffi-output-bound-"++os:getpid())),
          Max=(67108864-65536) div 6,
          {error,<<"invalid execute limits">>}=successor_python_ffi:execute(
            K,binary:copy(<<"x">>,4097),<<"ran_bad_id=True">>,1000,Max),
          {error,<<"invalid execute limits">>}=successor_python_ffi:execute(
            K,<<"too-large">>,<<"ran_too_large=True">>,1000,Max+1),
          {ok,{succeeded,Output,true}}=successor_python_ffi:execute(
            K,<<"boundary">>,<<"import sys; sys.stdout.write(chr(0) * 11173889)">>,30000,Max),
          Max=byte_size(Output), 0=binary:last(Output),
          {ok,{succeeded,<<"(False, False)\n">>,false}}=successor_python_ffi:execute(
            K,<<"healthy">>,<<"('ran_bad_id' in globals(), 'ran_too_large' in globals())">>,1000,1000),
          nil=successor_python_ffi:close(K), halt().""", timeout=45)

    def test_invalid_timer_is_refused_before_dispatch_and_kernel_stays_healthy(self):
        self.erl(r"""
          application:load(successor),
          {ok,K}=successor_python_ffi:start(list_to_binary("/tmp/successor-ffi-timer-"++os:getpid())),
          {error,<<"invalid execute limits">>}=successor_python_ffi:execute(
            K,<<"bad-zero">>,<<"ran_zero=True">>,0,1000),
          {error,<<"invalid execute limits">>}=successor_python_ffi:execute(
            K,<<"bad-large">>,<<"ran_large=True">>,4294937296,1000),
          {ok,{succeeded,<<"(False, False)\n">>,false}}=successor_python_ffi:execute(
            K,<<"healthy">>,<<"('ran_zero' in globals(), 'ran_large' in globals())">>,1000,1000),
          nil=successor_python_ffi:close(K), halt().""")

    def test_timeout_ends_kernel(self):
        self.erl(r"""
          application:load(successor),
          {ok,K}=successor_python_ffi:start(list_to_binary("/tmp/successor-ffi-timeout-"++os:getpid())),
          {ok,{unknown,_}}=successor_python_ffi:execute(K,<<"slow">>,<<"import time; time.sleep(30)">>,30,1000),
          timer:sleep(50), false=is_process_alive(K), halt().""")

    def test_close_interrupts_cell_and_owner_loss_reaps(self):
        self.erl(r"""
          application:load(successor), Parent=self(),
          Owner=spawn(fun()->
            {ok,K}=successor_python_ffi:start(list_to_binary("/tmp/successor-ffi-owner-"++os:getpid())),
            Parent!{owned,K}, receive stop -> ok end
          end),
          receive {owned,K1} -> exit(Owner,kill), timer:sleep(250), false=is_process_alive(K1) end,
          {ok,K2}=successor_python_ffi:start(list_to_binary("/tmp/successor-ffi-close-"++os:getpid())),
          spawn(fun()-> Parent!{dispatch,successor_python_ffi:execute(K2,<<"slow">>,<<"import time; time.sleep(30)">>,300000,1000)} end),
          timer:sleep(30), T=erlang:monotonic_time(millisecond), nil=successor_python_ffi:close(K2),
          receive {dispatch,{ok,{unknown,_}}} -> ok after 1000 -> error(dispatch_stuck) end,
          true=(erlang:monotonic_time(millisecond)-T < 1000), false=is_process_alive(K2), halt().""")

    def test_cpu_bound_kernel_timeout_reaps_guarded_target_and_forked_child(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            program = ("import os,subprocess,time; from pathlib import Path; "
                       "p=subprocess.Popen(['python3','-c','import time;time.sleep(30)']); "
                       "Path('owned-pids').write_text(f'{os.getpid()} {p.pid}'); "
                       "Path('effect').write_text('once'); time.sleep(30)")
            source = (f"job=run('python3','-c',{program!r})\n"
                      "while not Path('effect').exists(): await asyncio.sleep(.01)\nprint('ready')")
            def binary(text):
                return f"unicode:characters_to_binary({json.dumps(text)})"
            self.erl(f"""
              application:load(successor), W=list_to_binary({json.dumps(temporary)}),
              {{ok,K}}=successor_python_ffi:start(W),
              {{ok,{{succeeded,<<"ready\\n">>,false}}}}=successor_python_ffi:execute(
                K,<<"spawn">>,{binary(source)},5000,2000),
              {{ok,{{unknown,_}}}}=successor_python_ffi:execute(K,<<"cpu">>,<<"while True: pass">>,40,2000),
              {{ok,K2}}=successor_python_ffi:start(W),
              {{ok,{{succeeded,<<"False once\\n">>,false}}}}=successor_python_ffi:execute(
                K2,<<"fresh">>,<<"print('job' in globals(), Path('effect').read_text())">>,1000,2000),
              nil=successor_python_ffi:close(K2), halt().""", timeout=15)
            for pid in map(int, (root / "owned-pids").read_text().split()):
                try:
                    stat = Path(f"/proc/{pid}/stat").read_bytes().rsplit(b")", 1)[1].split()
                except FileNotFoundError:
                    continue
                self.assertEqual(stat[0], b"Z", f"owned pid {pid} is still runnable")
            self.assertEqual((root / "effect").read_text(), "once")

    def test_shared_job_lease_refuses_replacement_until_stopped_guardian_resumes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            program = "from pathlib import Path; import time; Path('ran').write_text('once'); time.sleep(30)"
            source = (f"job=run('python3','-c',{program!r})\n"
                      "while not Path('ran').exists(): await asyncio.sleep(.01)\n"
                      "Path('guard-pid').write_text(str(job._command.process.pid))\n"
                      "import os,signal; os.kill(job._command.process.pid,signal.SIGSTOP)")
            binary = f"unicode:characters_to_binary({json.dumps(source)})"
            try:
                self.erl(f"""
                  application:load(successor), W=list_to_binary({json.dumps(temporary)}),
                  {{ok,K}}=successor_python_ffi:start(W),
                  {{ok,{{succeeded,_,false}}}}=successor_python_ffi:execute(K,<<"spawn">>,{binary},5000,2000),
                  {{ok,{{unknown,_}}}}=successor_python_ffi:execute(K,<<"die">>,
                      <<"import os,signal; os.kill(os.getpid(),signal.SIGKILL)">>,1000,2000),
                  {{error,<<"python workspace is already active">>}}=successor_python_ffi:start(W),
                  halt().""", timeout=12)
            finally:
                if (root / 'guard-pid').exists():
                    pid = int((root / 'guard-pid').read_text())
                    try: os.kill(pid, signal.SIGCONT)
                    except ProcessLookupError: pass
            # A new real native startup, not a forged receipt, proves the inherited
            # lease has been released. No old command source is replayed.
            deadline = time.monotonic() + 6
            import fcntl
            while True:
                with (root / '.successor-runtime' / 'jobs.lock').open('rb') as lock:
                    try:
                        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        break
                    except BlockingIOError:
                        if time.monotonic() >= deadline: raise AssertionError('guardian did not drain')
                time.sleep(.02)
            self.erl(f"""
              application:load(successor), W=list_to_binary({json.dumps(temporary)}),
              {{ok,K}}=successor_python_ffi:start(W),
              {{ok,{{succeeded,<<"once\\n">>,false}}}}=successor_python_ffi:execute(
                  K,<<"retained">>,<<"print(Path('ran').read_text())">>,1000,2000),
              nil=successor_python_ffi:close(K), halt().""")

    def test_killed_guardian_leaves_cleanup_latch_and_refuses_unsafe_replacement(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            program = "from pathlib import Path; import os,time; Path('survivor-pid').write_text(str(os.getpid())); time.sleep(30)"
            source = (f"job=run('python3','-c',{program!r})\n"
                      "while not Path('survivor-pid').exists(): await asyncio.sleep(.005)\n"
                      "import os,signal; os.kill(job._command.process.pid,signal.SIGKILL)")
            binary = f"unicode:characters_to_binary({json.dumps(source)})"
            try:
                self.erl(f"""
                  application:load(successor), W=list_to_binary({json.dumps(temporary)}),
                  {{ok,K}}=successor_python_ffi:start(W),
                  {{ok,{{succeeded,_,false}}}}=successor_python_ffi:execute(K,<<"spawn">>,{binary},5000,2000),
                  nil=successor_python_ffi:close(K),
                  {{error,<<"python workspace is already active">>}}=successor_python_ffi:start(W),
                  halt().""", timeout=12)
                import fcntl
                with (root / '.successor-runtime' / 'jobs.lock').open('rb') as lock:
                    # Guardian is gone, so the original lease ALONE would admit.
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                markers = list((root / '.successor-runtime' / 'active-jobs').iterdir())
                self.assertEqual(len(markers), 1)
                pid = int((root / 'survivor-pid').read_text())
                self.assertTrue(Path(f'/proc/{pid}').exists())
                self.assertEqual(os.getpgid(pid), pid)
            finally:
                # Trusted test/operator reconciliation of our own captured token,
                # never a retry of command source or deletion without process proof.
                records = list((root / '.successor-runtime').glob('*.status.json'))
                for status_path in records:
                    record = json.loads(status_path.read_text())
                    pid = record['pid']
                    try:
                        token = Path(f'/proc/{pid}/stat').read_bytes().rsplit(b')',1)[1].split()[19].decode()
                        if token == record['leader']:
                            os.killpg(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    except FileNotFoundError:
                        pass
                deadline = time.monotonic()+3
                for record_path in records:
                    pid = json.loads(record_path.read_text())['pid']
                    while Path(f'/proc/{pid}/stat').exists():
                        state = Path(f'/proc/{pid}/stat').read_bytes().rsplit(b')',1)[1].split()[0]
                        if state==b'Z': break
                        if time.monotonic()>=deadline: raise AssertionError('owned target cleanup unproved')
                        time.sleep(.01)
                active = root / '.successor-runtime' / 'active-jobs'
                if active.exists():
                    for marker in active.iterdir(): marker.unlink()
            self.erl(f"""
              application:load(successor), W=list_to_binary({json.dumps(temporary)}),
              {{ok,K}}=successor_python_ffi:start(W),
              nil=successor_python_ffi:close(K), halt().""")


if __name__ == "__main__":
    unittest.main()
