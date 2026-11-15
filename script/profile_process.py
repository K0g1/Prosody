#!/usr/bin/env python3
"""Sample one macOS PID via libproc. CPU percent: 100% = one full CPU core.
Footprint includes compressed private memory; RSS is a different resident metric.
No root access or other-process telemetry is collected.
"""
import argparse
import csv
import ctypes
import time

parser = argparse.ArgumentParser()
parser.add_argument('pid', type=int)
parser.add_argument('--seconds', type=int, default=30)
parser.add_argument('--output', required=True)
args = parser.parse_args()
fields = '''user_time system_time pkg_idle_wkups interrupt_wkups pageins wired_size resident_size phys_footprint proc_start_abstime proc_exit_abstime child_user_time child_system_time child_pkg_idle_wkups child_interrupt_wkups child_pageins child_elapsed_abstime diskio_bytesread diskio_byteswritten cpu_time_qos_default cpu_time_qos_maintenance cpu_time_qos_background cpu_time_qos_utility cpu_time_qos_legacy cpu_time_qos_user_initiated cpu_time_qos_user_interactive billed_system_time serviced_system_time logical_writes lifetime_max_phys_footprint instructions cycles billed_energy serviced_energy interval_max_phys_footprint runnable_time flags user_ptime system_ptime pinstructions pcycles energy_nj penergy_nj secure_time_in_system secure_ptime_in_system neural_footprint lifetime_max_neural_footprint interval_max_neural_footprint'''.split()
class Usage(ctypes.Structure):
    _fields_ = [('uuid', ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in fields] + [('reserved', ctypes.c_uint64 * 9)]
lib = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
lib.proc_pid_rusage.restype = ctypes.c_int
class Timebase(ctypes.Structure):
    _fields_ = [('numer', ctypes.c_uint32), ('denom', ctypes.c_uint32)]
system = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
timebase = Timebase()
if system.mach_timebase_info(ctypes.byref(timebase)) != 0 or not timebase.denom:
    raise RuntimeError('Cannot read the Mach timebase')
seconds_per_tick = timebase.numer / timebase.denom / 1e9

def snapshot():
    value = Usage()
    if lib.proc_pid_rusage(args.pid, 6, ctypes.byref(value)) != 0:
        raise OSError(ctypes.get_errno(), 'proc_pid_rusage failed')
    return time.monotonic(), value

previous_time, previous = snapshot()
with open(args.output, 'w', newline='') as stream:
    writer = csv.writer(stream)
    writer.writerow(['elapsed_s', 'cpu_percent', 'footprint_mib', 'rss_mib', 'peak_footprint_mib', 'neural_mib', 'disk_read_bytes', 'disk_write_bytes', 'idle_wakeups'])
    started = previous_time
    for _ in range(args.seconds):
        time.sleep(1)
        now, current = snapshot()
        elapsed = now - previous_time
        cpu = ((current.user_time + current.system_time) - (previous.user_time + previous.system_time)) * seconds_per_tick / elapsed * 100
        writer.writerow([round(now-started, 3), round(cpu, 3), round(current.phys_footprint/2**20, 3), round(current.resident_size/2**20, 3), round(current.lifetime_max_phys_footprint/2**20, 3), round(current.neural_footprint/2**20, 3), current.diskio_bytesread-previous.diskio_bytesread, current.diskio_byteswritten-previous.diskio_byteswritten, current.pkg_idle_wkups-previous.pkg_idle_wkups])
        stream.flush()
        previous_time, previous = now, current
print(args.output)
