#ifndef _SPTRSV_SYNCFREE_CUDA_
#define _SPTRSV_SYNCFREE_CUDA_

#include "common.h"
#include "utils.h"
#include <cuda_runtime.h>

__global__
void sptrsv_syncfree_cuda_analyser(const int   *d_cscRowIdx,
                                   const int    m,
                                   const int    nnz,
                                         int   *d_graphInDegree)
{
    const int global_id = blockIdx.x * blockDim.x + threadIdx.x; //get_global_id(0);
    if (global_id < nnz)
    {
        atomicAdd(&d_graphInDegree[d_cscRowIdx[global_id]], 1);
    }
}

__global__
void sptrsv_syncfree_cuda_executor(const int* __restrict__        d_cscColPtr,
                                   const int* __restrict__        d_cscRowIdx,
                                   const VALUE_TYPE* __restrict__ d_cscVal,
                                         int*                     d_graphInDegree,
                                         VALUE_TYPE*              d_left_sum,
                                   const int                      m,
                                   const int                      substitution,
                                   const VALUE_TYPE* __restrict__ d_b,
                                         VALUE_TYPE*              d_x,
                                         int*                     d_while_profiler)
{
    const int global_id = blockIdx.x * blockDim.x + threadIdx.x;
    int global_x_id = global_id / WARP_SIZE;
    if (global_x_id >= m) return;

    // substitution is forward or backward
    global_x_id = substitution == SUBSTITUTION_FORWARD ? 
                  global_x_id : m - 1 - global_x_id;

    volatile __shared__ int s_graphInDegree[WARP_PER_BLOCK];
    volatile __shared__ VALUE_TYPE s_left_sum[WARP_PER_BLOCK];

    // Initialize
    const int local_warp_id = threadIdx.x / WARP_SIZE;
    const int lane_id = (WARP_SIZE - 1) & threadIdx.x;
    int starting_x = (global_id / (WARP_PER_BLOCK * WARP_SIZE)) * WARP_PER_BLOCK;
    starting_x = substitution == SUBSTITUTION_FORWARD ? 
                  starting_x : m - 1 - starting_x;
    
    // Prefetch
    const int pos = substitution == SUBSTITUTION_FORWARD ?
                    d_cscColPtr[global_x_id] : d_cscColPtr[global_x_id+1]-1;
    const VALUE_TYPE coef = (VALUE_TYPE)1 / d_cscVal[pos];
    //asm("prefetch.global.L2 [%0];"::"d"(d_cscVal[d_cscColPtr[global_x_id] + 1 + lane_id]));
    //asm("prefetch.global.L2 [%0];"::"r"(d_cscRowIdx[d_cscColPtr[global_x_id] + 1 + lane_id]));
	int tmp;
	
	
    if (threadIdx.x < WARP_PER_BLOCK) { s_graphInDegree[threadIdx.x] = 1; s_left_sum[threadIdx.x] = 0; }
    __syncthreads();

    clock_t start;
    // Consumer
    do {
        // start = clock();
		tmp = s_graphInDegree[local_warp_id]-d_graphInDegree[global_x_id];
		__threadfence();
    }
    while (tmp != 0);
  
    //// Consumer
    //int graphInDegree;
    //do {
    //    //bypass Tex cache and avoid other mem optimization by nvcc/ptxas
    //    asm("ld.global.u32 %0, [%1];" : "=r"(graphInDegree),"=r"(d_graphInDegree[global_x_id]) :: "memory"); 
    //}
    //while (s_graphInDegree[local_warp_id] != graphInDegree );

    VALUE_TYPE xi = d_left_sum[global_x_id] + s_left_sum[local_warp_id];
    xi = (d_b[global_x_id] - xi) * coef;

    // Producer
    const int start_ptr = substitution == SUBSTITUTION_FORWARD ? 
                          d_cscColPtr[global_x_id]+1 : d_cscColPtr[global_x_id];
    const int stop_ptr  = substitution == SUBSTITUTION_FORWARD ? 
                          d_cscColPtr[global_x_id+1] : d_cscColPtr[global_x_id+1]-1;
    for (int jj = start_ptr + lane_id; jj < stop_ptr; jj += WARP_SIZE)
    {
        const int j = substitution == SUBSTITUTION_FORWARD ? jj : stop_ptr - 1 - (jj - start_ptr);
        const int rowIdx = d_cscRowIdx[j];
        const bool cond = substitution == SUBSTITUTION_FORWARD ? 
                    (rowIdx < starting_x + WARP_PER_BLOCK) : (rowIdx > starting_x - WARP_PER_BLOCK);
        if (cond) {
            const int pos = substitution == SUBSTITUTION_FORWARD ? 
                            rowIdx - starting_x : starting_x - rowIdx;
            atomicAdd((VALUE_TYPE *)&s_left_sum[pos], xi * d_cscVal[j]);
            __threadfence_block();
            atomicAdd((int *)&s_graphInDegree[pos], 1);
        }
        else {
            atomicAdd(&d_left_sum[rowIdx], xi * d_cscVal[j]);
            __threadfence();
            atomicSub(&d_graphInDegree[rowIdx], 1);
        }
    }

    //finish
    if (!lane_id) d_x[global_x_id] = xi;
}


__global__
void sptrsm_syncfree_cuda_executor(const int* __restrict__        d_cscColPtr,
                                   const int* __restrict__        d_cscRowIdx,
                                   const VALUE_TYPE* __restrict__ d_cscVal,
                                         int*                     d_graphInDegree,
                                         VALUE_TYPE*              d_left_sum,
                                   const int                      m,
                                   const int                      substitution,
                                   const int                      rhs,
                                   const int                      opt,
                                   const VALUE_TYPE* __restrict__ d_b,
                                         VALUE_TYPE*              d_x,
                                         int*                     d_while_profiler)
{
    const int global_id = blockIdx.x * blockDim.x + threadIdx.x;
    int global_x_id = global_id / WARP_SIZE;
    if (global_x_id >= m) return;

    // substitution is forward or backward
    global_x_id = substitution == SUBSTITUTION_FORWARD ? 
                  global_x_id : m - 1 - global_x_id;

    // Initialize
    const int lane_id = (WARP_SIZE - 1) & threadIdx.x;

    // Prefetch
    const int pos = substitution == SUBSTITUTION_FORWARD ?
                d_cscColPtr[global_x_id] : d_cscColPtr[global_x_id+1]-1;
    const VALUE_TYPE coef = (VALUE_TYPE)1 / d_cscVal[pos];
    //asm("prefetch.global.L2 [%0];"::"d"(d_cscVal[d_cscColPtr[global_x_id] + 1 + lane_id]));
    //asm("prefetch.global.L2 [%0];"::"r"(d_cscRowIdx[d_cscColPtr[global_x_id] + 1 + lane_id]));

    clock_t start;
	int tmp;
    // Consumer
    do {
        // start = clock();
		tmp=d_graphInDegree[global_x_id];
		__threadfence();
    }
    while (1 != tmp);
  
    //// Consumer
    //int graphInDegree;
    //do {
    //    //bypass Tex cache and avoid other mem optimization by nvcc/ptxas
    //    asm("ld.global.u32 %0, [%1];" : "=r"(graphInDegree),"=r"(d_graphInDegree[global_x_id]) :: "memory"); 
    //}
    //while (1 != graphInDegree );

    for (int k = lane_id; k < rhs; k += WARP_SIZE)
    {
        const int pos = global_x_id * rhs + k;
        d_x[pos] = (d_b[pos] - d_left_sum[pos]) * coef;
    }

    // Producer
    const int start_ptr = substitution == SUBSTITUTION_FORWARD ? 
                          d_cscColPtr[global_x_id]+1 : d_cscColPtr[global_x_id];
    const int stop_ptr  = substitution == SUBSTITUTION_FORWARD ? 
                          d_cscColPtr[global_x_id+1] : d_cscColPtr[global_x_id+1]-1;

    if (opt == OPT_WARP_NNZ)
    {
        for (int jj = start_ptr + lane_id; jj < stop_ptr; jj += WARP_SIZE)
        {
            const int j = substitution == SUBSTITUTION_FORWARD ? jj : stop_ptr - 1 - (jj - start_ptr);
            const int rowIdx = d_cscRowIdx[j];
            for (int k = 0; k < rhs; k++)
                atomicAdd(&d_left_sum[rowIdx * rhs + k], d_x[global_x_id * rhs + k] * d_cscVal[j]);
            __threadfence();
            atomicSub(&d_graphInDegree[rowIdx], 1);
        }
    }
    else if (opt == OPT_WARP_RHS)
    {
        for (int jj = start_ptr; jj < stop_ptr; jj++)
        {
            const int j = substitution == SUBSTITUTION_FORWARD ? jj : stop_ptr - 1 - (jj - start_ptr);
            const int rowIdx = d_cscRowIdx[j];
            for (int k = lane_id; k < rhs; k+=WARP_SIZE)
                atomicAdd(&d_left_sum[rowIdx * rhs + k], d_x[global_x_id * rhs + k] * d_cscVal[j]);
            __threadfence();
            if (!lane_id) atomicSub(&d_graphInDegree[rowIdx], 1);
        }
    }
    else if (opt == OPT_WARP_AUTO)
    {
        const int len = stop_ptr - start_ptr;

        if ((len <= rhs || rhs > 16) && len < 2048)
        {
            for (int jj = start_ptr; jj < stop_ptr; jj++)
            {
                const int j = substitution == SUBSTITUTION_FORWARD ? jj : stop_ptr - 1 - (jj - start_ptr);
                const int rowIdx = d_cscRowIdx[j];
                for (int k = lane_id; k < rhs; k+=WARP_SIZE)
                    atomicAdd(&d_left_sum[rowIdx * rhs + k], d_x[global_x_id * rhs + k] * d_cscVal[j]);
                __threadfence();
                if (!lane_id) atomicSub(&d_graphInDegree[rowIdx], 1);
            }
        }
        else
        {
            for (int jj = start_ptr + lane_id; jj < stop_ptr; jj += WARP_SIZE)
            {
                const int j = substitution == SUBSTITUTION_FORWARD ? jj : stop_ptr - 1 - (jj - start_ptr);
                const int rowIdx = d_cscRowIdx[j];
                for (int k = 0; k < rhs; k++)
                    atomicAdd(&d_left_sum[rowIdx * rhs + k], d_x[global_x_id * rhs + k] * d_cscVal[j]);
                __threadfence();
                atomicSub(&d_graphInDegree[rowIdx], 1);
            }
        }
    }
}

int sptrsv_syncfree_cuda(const int           *cscColPtrTR,
                         const int           *cscRowIdxTR,
                         const VALUE_TYPE    *cscValTR,
                         const int            m,
                         const int            n,
                         const int            nnzTR,
                         const int            substitution,
                         const int            rhs,
                         const int            opt,
                               VALUE_TYPE    *x,
                         const VALUE_TYPE    *b,
                         const VALUE_TYPE    *x_ref,
                               double        *gflops)
{
    if (m != n)
    {
        printf("This is not a square matrix, return.\n");
        return -1;
    }

    // transfer host mem to device mem
    int *d_cscColPtrTR;
    int *d_cscRowIdxTR;
    VALUE_TYPE *d_cscValTR;
    VALUE_TYPE *d_b;
    VALUE_TYPE *d_x;

    // Matrix L
    cudaMalloc((void **)&d_cscColPtrTR, (n+1) * sizeof(int));
    cudaMalloc((void **)&d_cscRowIdxTR, nnzTR  * sizeof(int));
    cudaMalloc((void **)&d_cscValTR,    nnzTR  * sizeof(VALUE_TYPE));

    cudaMemcpy(d_cscColPtrTR, cscColPtrTR, (n+1) * sizeof(int),   cudaMemcpyHostToDevice);
    cudaMemcpy(d_cscRowIdxTR, cscRowIdxTR, nnzTR  * sizeof(int),   cudaMemcpyHostToDevice);
    cudaMemcpy(d_cscValTR,    cscValTR,    nnzTR  * sizeof(VALUE_TYPE),   cudaMemcpyHostToDevice);

    // Vector b
    cudaMalloc((void **)&d_b, m * rhs * sizeof(VALUE_TYPE));
    cudaMemcpy(d_b, b, m * rhs * sizeof(VALUE_TYPE), cudaMemcpyHostToDevice);

    // Vector x
    cudaMalloc((void **)&d_x, n * rhs * sizeof(VALUE_TYPE));
    cudaMemset(d_x, 0, n * rhs * sizeof(VALUE_TYPE));

    //  - cuda syncfree SpTRSV analysis start!
    printf(" - cuda syncfree SpTRSV analysis start!\n");

    struct timeval t1, t2;
    gettimeofday(&t1, NULL);

    // malloc tmp memory to generate in-degree
    int *d_graphInDegree;
    int *d_graphInDegree_backup;
    cudaMalloc((void **)&d_graphInDegree, m * sizeof(int));
    cudaMalloc((void **)&d_graphInDegree_backup, m * sizeof(int));

    int num_threads = 128;
    int num_blocks = ceil ((double)nnzTR / (double)num_threads);

    for (int i = 0; i < BENCH_REPEAT; i++)
    {
        cudaMemset(d_graphInDegree, 0, m * sizeof(int));
        sptrsv_syncfree_cuda_analyser<<< num_blocks, num_threads >>>
                                      (d_cscRowIdxTR, m, nnzTR, d_graphInDegree);
    }
    cudaDeviceSynchronize();

    gettimeofday(&t2, NULL);
    double time_cuda_analysis = (t2.tv_sec - t1.tv_sec) * 1000.0 + (t2.tv_usec - t1.tv_usec) / 1000.0;
    time_cuda_analysis /= BENCH_REPEAT;

    printf("cuda syncfree SpTRSV analysis on L used %4.2f ms\n", time_cuda_analysis);

    //  - cuda syncfree SpTRSV solve start!
    printf(" - cuda syncfree SpTRSV solve start!\n");

    // malloc tmp memory to collect a partial sum of each row
    VALUE_TYPE *d_left_sum;
    cudaMalloc((void **)&d_left_sum, sizeof(VALUE_TYPE) * m * rhs);

    // backup in-degree array, only used for benchmarking multiple runs
    cudaMemcpy(d_graphInDegree_backup, d_graphInDegree, m * sizeof(int), cudaMemcpyDeviceToDevice);

    // this is for profiling while loop only
    int *d_while_profiler;
    cudaMalloc((void **)&d_while_profiler, sizeof(int) * n);
    cudaMemset(d_while_profiler, 0, sizeof(int) * n);
    int *while_profiler = (int *)malloc(sizeof(int) * n);

    // step 5: solve L*y = x
    double time_cuda_solve = 0;

    for (int i = 0; i < BENCH_REPEAT; i++)
    {
        // get a unmodified in-degree array, only for benchmarking use
        cudaMemcpy(d_graphInDegree, d_graphInDegree_backup, m * sizeof(int), cudaMemcpyDeviceToDevice);
        
        // clear left_sum array, only for benchmarking use
        cudaMemset(d_left_sum, 0, sizeof(VALUE_TYPE) * m * rhs);
        cudaMemset(d_x, 0, sizeof(VALUE_TYPE) * n * rhs);

        gettimeofday(&t1, NULL);

        if (rhs == 1)
        {
            num_threads = WARP_PER_BLOCK * WARP_SIZE;
            num_blocks = ceil ((double)m / (double)(num_threads/WARP_SIZE));
            sptrsv_syncfree_cuda_executor<<< num_blocks, num_threads >>>
                                         (d_cscColPtrTR, d_cscRowIdxTR, d_cscValTR,
                                          d_graphInDegree, d_left_sum,
                                          m, substitution, d_b, d_x, d_while_profiler);
        }
        else
        {
            num_threads = 4 * WARP_SIZE;
            num_blocks = ceil ((double)m / (double)(num_threads/WARP_SIZE));
            sptrsm_syncfree_cuda_executor<<< num_blocks, num_threads >>>
                                         (d_cscColPtrTR, d_cscRowIdxTR, d_cscValTR,
                                          d_graphInDegree, d_left_sum,
                                          m, substitution, rhs, opt,
                                          d_b, d_x, d_while_profiler);
        }

        cudaDeviceSynchronize();
        gettimeofday(&t2, NULL);

        time_cuda_solve += (t2.tv_sec - t1.tv_sec) * 1000.0 + (t2.tv_usec - t1.tv_usec) / 1000.0;
    }

    time_cuda_solve /= BENCH_REPEAT;
    double flop = 2*(double)rhs*(double)nnzTR;

    printf("cuda syncfree SpTRSV solve used %4.2f ms, throughput is %4.2f gflops\n",
           time_cuda_solve, flop/(1e6*time_cuda_solve));
    *gflops = flop/(1e6*time_cuda_solve);

    cudaMemcpy(x, d_x, n * rhs * sizeof(VALUE_TYPE), cudaMemcpyDeviceToHost);

    // validate x
    double accuracy = 1e-4;
    double ref = 0.0;
    double res = 0.0;

    for (int i = 0; i < n * rhs; i++)
    {
        ref += abs(x_ref[i]);
        res += abs(x[i] - x_ref[i]);
        //if (x_ref[i] != x[i]) printf ("[%i, %i] x_ref = %f, x = %f\n", i/rhs, i%rhs, x_ref[i], x[i]);
    }
    res = ref == 0 ? res : res / ref;

    if (res < accuracy)
        printf("cuda syncfree SpTRSV executor passed! |x-xref|/|xref| = %8.2e\n", res);
    else
        printf("cuda syncfree SpTRSV executor _NOT_ passed! |x-xref|/|xref| = %8.2e\n", res);

    // profile while loop
    cudaMemcpy(while_profiler, d_while_profiler, n * sizeof(int), cudaMemcpyDeviceToHost);
    long long unsigned int while_count = 0;
    for (int i = 0; i < n; i++)
    {
        while_count += while_profiler[i];
        //printf("while_profiler[%i] = %i\n", i, while_profiler[i]);
    }
    //printf("\nwhile_count= %llu in total, %llu per row/column\n", while_count, while_count/m);

    // step 6: free resources
    free(while_profiler);

    cudaFree(d_graphInDegree);
    cudaFree(d_graphInDegree_backup);
    cudaFree(d_left_sum);
    cudaFree(d_while_profiler);

    cudaFree(d_cscColPtrTR);
    cudaFree(d_cscRowIdxTR);
    cudaFree(d_cscValTR);
    cudaFree(d_b);
    cudaFree(d_x);

    return 0;
}

#endif



