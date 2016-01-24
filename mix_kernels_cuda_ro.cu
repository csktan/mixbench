/**
 * mix_kernels_cuda_ro.cu: This file is part of the mixbench GPU micro-benchmark suite.
 *
 * Contact: Elias Konstantinidis <ekondis@gmail.com>
 **/

#include <stdio.h>
#include <math_constants.h>
#include "lcutil.h"

#define ELEMENTS_PER_THREAD (8)

template <class T, int blockdim, unsigned int granularity, unsigned int compute_iterations>
__global__ void benchmark_func(T seed, T *g_data){
	const unsigned int blockSize = blockdim;
	const int stride = blockSize;
	int idx = blockIdx.x*blockSize*granularity + threadIdx.x;

	T tmps[granularity];
	// Load elements (memory intensive part)
	#pragma unroll
	for(int j=0; j<granularity; j++)
		tmps[j] = g_data[idx+j*stride];
	// Perform computations (compute intensive part)
	#pragma unroll 512
	for(int i=0; i<compute_iterations; i++){
		#pragma unroll
		for(int j=0; j<granularity; j++)
			tmps[j] = tmps[j]*tmps[j]+tmps[(j+granularity/2)%granularity];
	}
	// Multiply add reduction
	T sum = (T)0;
	#pragma unroll
	for(int j=0; j<granularity; j+=2)
		sum += tmps[j]*tmps[j+1];
	// Dummy code
	if( sum==(T)-1 ){ // Designed so it never executes
		#pragma unroll
		for(int j=0; j<granularity; j++)
			g_data[idx] = sum;
	}
}

void initializeEvents(cudaEvent_t *start, cudaEvent_t *stop){
	CUDA_SAFE_CALL( cudaEventCreate(start) );
	CUDA_SAFE_CALL( cudaEventCreate(stop) );
	CUDA_SAFE_CALL( cudaEventRecord(*start, 0) );
}

float finalizeEvents(cudaEvent_t start, cudaEvent_t stop){
	CUDA_SAFE_CALL( cudaGetLastError() );
	CUDA_SAFE_CALL( cudaEventRecord(stop, 0) );
	CUDA_SAFE_CALL( cudaEventSynchronize(stop) );
	float kernel_time;
	CUDA_SAFE_CALL( cudaEventElapsedTime(&kernel_time, start, stop) );
	CUDA_SAFE_CALL( cudaEventDestroy(start) );
	CUDA_SAFE_CALL( cudaEventDestroy(stop) );
	return kernel_time;
}

void runbench_warmup(double *cd, long size){
	const long reduced_grid_size = size/(ELEMENTS_PER_THREAD)/128;
	const int BLOCK_SIZE = 256;
	const int TOTAL_REDUCED_BLOCKS = reduced_grid_size/BLOCK_SIZE;

	dim3 dimBlock(BLOCK_SIZE, 1, 1);
	dim3 dimReducedGrid(TOTAL_REDUCED_BLOCKS, 1, 1);

	benchmark_func< short, BLOCK_SIZE, ELEMENTS_PER_THREAD, 0 ><<< dimReducedGrid, dimBlock >>>((short)1, (short*)cd);
	CUDA_SAFE_CALL( cudaGetLastError() );
	CUDA_SAFE_CALL( cudaThreadSynchronize() );
}

template<unsigned int compute_iterations>
void runbench(double *cd, long size){
	const long compute_grid_size = size/ELEMENTS_PER_THREAD;
	const int BLOCK_SIZE = 256;
	const int TOTAL_BLOCKS = compute_grid_size/BLOCK_SIZE;
	const long long computations = ELEMENTS_PER_THREAD*compute_grid_size+(2*ELEMENTS_PER_THREAD*compute_iterations)*compute_grid_size;
	const long long memoryoperations = size;

	dim3 dimBlock(BLOCK_SIZE, 1, 1);
	dim3 dimGrid(TOTAL_BLOCKS, 1, 1);
	cudaEvent_t start, stop;

	initializeEvents(&start, &stop);
	benchmark_func< float, BLOCK_SIZE, ELEMENTS_PER_THREAD, compute_iterations ><<< dimGrid, dimBlock >>>(1.0f, (float*)cd);
	float kernel_time_mad_sp = finalizeEvents(start, stop);

	initializeEvents(&start, &stop);
	benchmark_func< double, BLOCK_SIZE, ELEMENTS_PER_THREAD, compute_iterations ><<< dimGrid, dimBlock >>>(1.0, cd);
	float kernel_time_mad_dp = finalizeEvents(start, stop);

	initializeEvents(&start, &stop);
	benchmark_func< int, BLOCK_SIZE, ELEMENTS_PER_THREAD, compute_iterations ><<< dimGrid, dimBlock >>>(1, (int*)cd);
	float kernel_time_mad_int = finalizeEvents(start, stop);

	printf("  %8.3f,%8.2f,%8.2f,%7.2f,   %8.3f,%8.2f,%8.2f,%7.2f,  %8.3f,%8.2f,%8.2f,%7.2f\n", 
		((double)computations)/((double)memoryoperations*sizeof(float)),
		kernel_time_mad_sp,
		((double)computations)/kernel_time_mad_sp*1000./(double)(1000*1000*1000),
		((double)memoryoperations*sizeof(float))/kernel_time_mad_sp*1000./(1000.*1000.*1000.),
		((double)computations)/((double)memoryoperations*sizeof(double)),
		kernel_time_mad_dp,
		((double)computations)/kernel_time_mad_dp*1000./(double)(1000*1000*1000),
		((double)memoryoperations*sizeof(double))/kernel_time_mad_dp*1000./(1000.*1000.*1000.),
		((double)computations)/((double)memoryoperations*sizeof(int)),
		kernel_time_mad_int,
		((double)computations)/kernel_time_mad_int*1000./(double)(1000*1000*1000),
		((double)memoryoperations*sizeof(int))/kernel_time_mad_int*1000./(1000.*1000.*1000.) );
}

extern "C" void mixbenchGPU(double *c, long size){
	const char *benchtype = "compute with global memory (block strided)";

	printf("Trade-off type:%s\n", benchtype);
	double *cd;

	CUDA_SAFE_CALL( cudaMalloc((void**)&cd, size*sizeof(double)) );

	// Copy data to device memory
	CUDA_SAFE_CALL( cudaMemset(cd, 0, size*sizeof(double)) );  // initialize to zeros

	// Synchronize in order to wait for memory operations to finish
	CUDA_SAFE_CALL( cudaThreadSynchronize() );

	printf("--------------------------------------------------- CSV data --------------------------------------------------\n");
	printf("Single Precision ops,,,,              Double precision ops,,,,              Integer operations,,, \n");
	printf("Flops/byte, ex.time,  GFLOPS, GB/sec, Flops/byte, ex.time,  GFLOPS, GB/sec, Iops/byte, ex.time,   GIOPS, GB/sec\n");

	runbench_warmup(cd, size);

	runbench<0>(cd, size);
	runbench<1>(cd, size);
	runbench<2>(cd, size);
	runbench<3>(cd, size);
	runbench<4>(cd, size);
	runbench<5>(cd, size);
	runbench<6>(cd, size);
	runbench<7>(cd, size);
	runbench<8>(cd, size);
	runbench<9>(cd, size);
	runbench<10>(cd, size);
	runbench<11>(cd, size);
	runbench<12>(cd, size);
	runbench<13>(cd, size);
	runbench<14>(cd, size);
	runbench<15>(cd, size);
	runbench<16>(cd, size);
	runbench<18>(cd, size);
	runbench<20>(cd, size);
	runbench<24>(cd, size);
	runbench<32>(cd, size);
	runbench<48>(cd, size);
	runbench<64>(cd, size);
	runbench<96>(cd, size);
	runbench<128>(cd, size);
	runbench<256>(cd, size);
	runbench<512>(cd, size);
	runbench<768>(cd, size);
	runbench<1024>(cd, size);
	runbench<1536>(cd, size);
	runbench<2048>(cd, size);

	printf("---------------------------------------------------------------------------------------------------------------\n");

	// Copy results back to host memory
	CUDA_SAFE_CALL( cudaMemcpy(c, cd, size*sizeof(double), cudaMemcpyDeviceToHost) );

	CUDA_SAFE_CALL( cudaFree(cd) );

	CUDA_SAFE_CALL( cudaDeviceReset() );
}
