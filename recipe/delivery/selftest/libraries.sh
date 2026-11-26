#!/bin/sh
set -eu
nc-config --has-parallel4 | grep -qx yes
pkg-config --exists elpa_openmp
cat > parallel.c <<'C'
#include <mpi.h>
#include <hdf5.h>
#include <netcdf.h>
#include <netcdf_par.h>
#include <fftw3.h>

#define REQUIRE(ok) do { if (!(ok)) MPI_Abort(MPI_COMM_WORLD, __LINE__); } while (0)
int main(int argc, char **argv) {
    int file;
    MPI_Init(&argc, &argv);
    hid_t access = H5Pcreate(H5P_FILE_ACCESS);
    REQUIRE(access >= 0 && H5Pset_fapl_mpio(access, MPI_COMM_WORLD, MPI_INFO_NULL) >= 0);
    hid_t h5 = H5Fcreate("parallel.h5", H5F_ACC_TRUNC, H5P_DEFAULT, access);
    REQUIRE(h5 >= 0 && H5Fclose(h5) >= 0);
    REQUIRE(H5Pclose(access) >= 0);
    REQUIRE(nc_create_par("parallel.nc", NC_NETCDF4, MPI_COMM_WORLD, MPI_INFO_NULL, &file) == NC_NOERR);
    REQUIRE(nc_close(file) == NC_NOERR);
    fftw_complex input[2] = {{1.0, 0.0}, {2.0, 0.0}}, output[2];
    fftw_plan plan = fftw_plan_dft_1d(2, input, output, FFTW_FORWARD, FFTW_ESTIMATE);
    REQUIRE(plan != NULL);
    fftw_execute(plan);
    REQUIRE(output[0][0] == 3.0 && output[1][0] == -1.0);
    fftw_destroy_plan(plan);
    MPI_Finalize();
    return 0;
}
C
mpicc -I/usr/local/include parallel.c -L/usr/local/lib -lhdf5 -lnetcdf -lfftw3 -o parallel
mpirun -n 2 ./parallel
test -s parallel.h5
test -s parallel.nc
