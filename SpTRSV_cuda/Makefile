#compilers
CC=nvcc

#GLOBAL_PARAMETERS
VALUE_TYPE = double

#CUDA_PARAMETERS
NVCC_FLAGS = -O3 -w -m64 -Xptxas -dlcm=cg -gencode arch=compute_70,code=sm_70 
#NVCC_FLAGS = -g -G -gencode arch=compute_70,code=sm_70 

#ENVIRONMENT_PARAMETERS
CUDA_INSTALL_PATH = ${OLCF_CUDA_ROOT}

#includes
INCLUDES = -I$(CUDA_INSTALL_PATH)/include

#libs
#CLANG_LIBS = -stdlib=libstdc++ -lstdc++
CUDA_LIBS = -L$(CUDA_INSTALL_PATH)/lib64  -lcudart
LIBS = $(CUDA_LIBS)

#options
#OPTIONS = -std=c99

make:
	$(CC) $(NVCC_FLAGS) main.cu -o sptrsv $(INCLUDES) $(LIBS) $(OPTIONS) -D VALUE_TYPE=$(VALUE_TYPE)
