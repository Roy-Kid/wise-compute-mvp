"""执行面任务：只依赖镜像，不依赖 wisehub / Dev Container CLI。"""
import numpy as np
from mpi4py import MPI

comm = MPI.COMM_WORLD
local = np.full(4, comm.rank, dtype="f8")
total = comm.allreduce(local.sum())
if comm.rank == 0:
    expected = 4 * sum(range(comm.size))
    print(f"ranks={comm.size} allreduce={total} expected={expected} "
          f"{'OK' if total == expected else 'MISMATCH'}")
    print(MPI.Get_library_version().splitlines()[0])
