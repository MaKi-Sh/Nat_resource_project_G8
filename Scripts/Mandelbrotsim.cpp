// ===================================================================
// Mandelbrot Set Renderer (Sequential + MPI Parallel)
// -------------------------------------------------------------------
// Generates a grayscale image of the Mandelbrot set and writes it to
// a PPM file. Includes both a single-threaded version (`sequential`)
// and a master/slave MPI version (`parallelStatic`) that splits the
// image into row-bands across worker processes.
// ===================================================================

#include "mpi.h"        // MPI library for distributed/parallel processing
#include <complex>      // std::complex<double> for complex number arithmetic
#include <iostream>     // console I/O (cout)
#include <fstream>      // file I/O (ofstream, used to write the PPM image)
#include <chrono>       // high-resolution timing for benchmarking

using namespace std;
using namespace complex_literals;

// ---------- Render configuration ----------
const int max_iter = 8192;     // Maximum iterations before declaring a point "in" the set.
                               // Higher = more detail near the boundary, but slower.
const int width  = 3840;       // Output image width  (pixels) — 4K horizontal resolution
const int height = 3840;       // Output image height (pixels) — square aspect ratio

// Bounds of the region of the complex plane we are sampling.
// The classic Mandelbrot view sits roughly within [-2.5, 1.5] x [-2.0, 2.0].
const double rmin = -2.5;      // minimum real part      (left edge of image)
const double rmax =  1.5;      // maximum real part      (right edge of image)
const double imin = -2.0;      // minimum imaginary part (bottom edge of image)
const double imax =  2.0;      // maximum imaginary part (top edge of image)

// -------------------------------------------------------------------
// getMandelbrotN
//   For a given complex number c, iterates z_{n+1} = z_n^2 + c starting
//   from z_0 = 0, and returns the number of iterations before |z|^2
//   exceeds 4 (the standard escape radius squared). If we never escape
//   within max_iter steps, we treat c as "inside" the set.
//   The returned count `n` is later mapped to a pixel color.
// -------------------------------------------------------------------
int getMandelbrotN(complex<double> c)
{

    int n = 0;                              // iteration counter
    double magnitude = 0;                   // |z|^2 — squared modulus (avoids a sqrt)
    complex<double> z(0.0, 0.0);            // start the orbit at z = 0
    while ((n < max_iter) && (magnitude < 4))
    {
        z = z * z + c;                                          // Mandelbrot recurrence
        magnitude = (z.real() * z.real()) + (z.imag() * z.imag()); // |z|^2
        n++;
    }
    return n;   // number of iterations survived (== max_iter if point is in the set)
}

// -------------------------------------------------------------------
// mapPixelToComplexPlane
//   Converts an integer pixel coordinate (x, y) in the image into the
//   corresponding complex number c on the plane we are sampling.
//   Pixel (0,0) maps to (rmin, imin); pixel (width, height) maps to
//   (rmax, imax).
// -------------------------------------------------------------------
complex<double> mapPixelToComplexPlane(int x, int y)
{
    // range/width gives step size for each pixel
    double horizontalRange = rmax - rmin;                    // total span on real axis
    double newCReal = x * (horizontalRange / width) + rmin;  // x-pixel -> real component

    double verticalRange = imax - imin;                      // total span on imaginary axis
    double newCImag = y * (verticalRange / height) + imin;   // y-pixel -> imaginary component

    return complex<double>(newCReal, newCImag);
}

// -------------------------------------------------------------------
// sequential
//   Single-process reference implementation. Walks every pixel in
//   row-major order, computes its Mandelbrot iteration count, and
//   writes a grayscale PPM file. Useful for correctness comparison
//   against the parallel version (and for timing baselines).
// -------------------------------------------------------------------
void sequential()
{

    // open the output file, write the ppm header
    ofstream fout("output_image.ppm");
    fout << "P3" << endl;                   // magic number — "P3" = ASCII RGB PPM format
    fout << width << " " << height << endl; // our dimensions
    fout << "255" << endl;                  // max value of a rgb pixel (8-bit channels)

    // Walk the image grid pixel by pixel.
    for (int y = 0; y < height; y++)
    { // row
        for (int x = 0; x < width; x++)
        { // the pixels in each row
            complex<double> c = mapPixelToComplexPlane(x, y);   // pixel -> complex point
            int n = getMandelbrotN(c);                          // iterations before escape

            // coloring the pixel
            // Simple grayscale mapping: take iteration count modulo 256 so it
            // fits in a single 8-bit channel. Same value used for R, G, and B
            // -> grayscale output.
            int color = (n % 256);
            fout << color << " " << color << " " << color << " "; // represents one pixel
        }
        fout << endl;   // newline between rows keeps the PPM ASCII file readable
    }
    fout.close();
    cout << "Finished" << endl;
}

// -------------------------------------------------------------------
// parallelStatic
//   Master/Slave MPI implementation with a STATIC row partitioning:
//     - Rank 0 is the master: it hands each worker a starting row,
//       then receives computed pixels and assembles the final image.
//     - Ranks 1..size-1 are workers: each handles a contiguous band
//       of rows and ships pixel results back to the master.
//
//   Note: because rank 0 only coordinates, the actual compute is split
//   across (size - 1) workers. Run with at least 2 MPI ranks.
// -------------------------------------------------------------------
void parallelStatic(const int size, const int rank)
{
    if (size < 2)
    {
        if (rank == 0)
            cout << "parallelStatic requires at least 2 MPI ranks (1 master + >=1 worker)." << endl;
        return;
    }

    // Each worker gets a band of `rowIncrement` consecutive rows.
    // We divide by (size - 1) because rank 0 doesn't compute pixels.
    int rowIncrement = height / (size - 1); // size - 1 because master node will not be processing
    // The last rank (rank == size - 1) adjusts its endpoint to ensure all remaining rows up to 'height' are processed.

    if (rank == 0)
    {
        // -------------------- MASTER (rank 0) --------------------
        char processor[MPI_MAX_PROCESSOR_NAME];
        int processorNameLength;
        MPI_Get_processor_name(processor, &processorNameLength);    // hostname for logging
        cout << processor << " rank " << rank << ": Sending rows..." << endl;
        MPI_Barrier(MPI_COMM_WORLD);    // sync all ranks before dispatch

        // Phase 1: tell each worker which row to start at.
        int row = 0;
        for (int i = 1; i < size; i++)
        {
            MPI_Send(&row, 1, MPI_INT, i, 0, MPI_COMM_WORLD); // tag=0 -> "this is your start row"
            row += rowIncrement;
        }
        cout << processor << " rank " << rank << ": Rows sent." << endl;

        cout << processor << " rank " << rank << ": Receiving rows... (LISTENING)" << endl;

        MPI_Barrier(MPI_COMM_WORLD);    // sync before workers start streaming results

        // Phase 2: allocate a 2D buffer to hold the assembled image.
        // rows[y][x] will hold the iteration count for pixel (x, y).
        int **rows = new int *[height];
        for (int i = 0; i < height; ++i)
        {
            rows[i] = new int[width];
        }
		
        // Phase 3: collect exactly width*height pixel packets from any worker.
        // MPI_ANY_SOURCE means we don't care which rank produced which pixel —
        // the (x, y) coords inside the packet tell us where it belongs.
        cout << processor << " rank " << rank << ": Rows received." << endl;
		
		auto row_buf = new int[width];
		for (int i = 0; i < height; i++) {
		    MPI_Status status;
		    MPI_Recv(row_buf, width, MPI_INT, MPI_ANY_SOURCE, MPI_ANY_TAG, MPI_COMM_WORLD, &status);
		    int y = status.MPI_TAG;
		    for (int x = 0; x < width; x++) rows[y][x] = row_buf[x];
		}
		delete[] row_buf;
        MPI_Barrier(MPI_COMM_WORLD);    // sync before writing the file

        // Phase 4: write the PPM file from the assembled buffer.
        cout << processor << " rank " << rank << ": Coloring image..." << endl;
        ofstream fout("parallel_output_image.ppm");
        fout << "P3" << endl;                   // magic number
        fout << width << " " << height << endl; // our dimensions
        fout << "255" << endl;                  // max value of a rgb pixel
        int color = 0;
        for (int y = 0; y < height; y++)
        {
            for (int x = 0; x < width; x++)
            {
                color = rows[y][x];
                fout << color << " " << color << " " << color << " "; // represents one pixel
            }
            fout << endl;
        }

        // Free the buffer to avoid leaking ~4K * 4K * sizeof(int) bytes.
        for (int i = 0; i < height; ++i)
        {
            delete[] rows[i];
        }
        delete[] rows;
        fout.close();
        cout << processor << " rank " << rank << ": Image has been colored." << endl;
    }
    else
    { // else if slave node -> process and return a color (int)
        // -------------------- WORKER (rank > 0) --------------------
        char processor[MPI_MAX_PROCESSOR_NAME];
        int processorNameLength;
        MPI_Get_processor_name(processor, &processorNameLength);
        MPI_Barrier(MPI_COMM_WORLD);    // matches master's first barrier

        // Phase 1: receive our assigned starting row from the master (tag 0).
        int startRow = 0;
        cout << processor << " rank " << rank << ": Receiving rows..." << endl;
        MPI_Recv(&startRow, 1, MPI_INT, 0, 0, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
        cout << processor << " rank " << rank << ": Received rows, " << " starting at " << startRow << endl;

        MPI_Barrier(MPI_COMM_WORLD);    // matches master's second barrier

        // Phase 2: compute every pixel in our row band and stream it back.
        cout << processor << " rank " << rank << ": Processing colors and gridpoints" << endl;

        // The last rank picks up any leftover rows from the integer division above
        // (i.e. it processes through `height` instead of stopping at startRow + rowIncrement).
		auto row_buf = new int[width];
		int y_end = (rank == size - 1) ? height : startRow + rowIncrement;
		for(int y = startRow; y < y_end; y++){
			for (int x = 0; x < width; x++){
				complex<double> c = mapPixelToComplexPlane(x, y); 
				row_buf[x] = getMandelbrotN(c) % 256; 
			}
			MPI_Send(row_buf, width, MPI_INT, 0, y, MPI_COMM_WORLD);
		}
		delete[] row_buf; 
        MPI_Barrier(MPI_COMM_WORLD);    // matches master's final barrier
    }
}

// -------------------------------------------------------------------
// main
//   Initializes MPI, runs the parallel renderer, and prints the total
//   wall-clock time. Each rank executes this function; rank 0 will be
//   the master inside parallelStatic, the rest are workers.
// -------------------------------------------------------------------
int main(int argc, char *argv[])
{
		auto start = std::chrono::steady_clock::now();   // wall-clock start
        MPI_Init(&argc, &argv);                          // start the MPI runtime
        int worldSize;
        int worldRank;
        MPI_Comm_size(MPI_COMM_WORLD, &worldSize);       // total number of ranks
        MPI_Comm_rank(MPI_COMM_WORLD, &worldRank);       // this process's rank id
        parallelStatic(worldSize, worldRank);            // run the renderer
        MPI_Finalize();                                  // shut down the MPI runtime
		auto end = std::chrono::steady_clock::now();     // wall-clock end
		auto difference = end - start;
		cout << chrono::duration_cast<chrono::milliseconds>(difference).count() << " ms" << endl;
}
