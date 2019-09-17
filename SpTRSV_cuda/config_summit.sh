module load cuda 

rm -rf sptrsv
make VALUE_TYPE=double
export OMP_NUM_THREADS=1

nrhs=100

FORMAT=dat
INPUT_DIR=$MEMBERWORK/csc289/matrix/SuperLU_Lfactor
#for MAT in copter2L.dat epb3L.dat gridgenaL.dat vanbodyL.dat shipsec1L.dat dawson5L.dat gas_sensorL.dat rajat16L.dat
for MAT in epb3L.dat 
do

#FORMAT=mtx
#INPUT_DIR=$MEMBERWORK/csc289/matrix/HTS
#for MAT in copter2.mtx
#do

jsrun -n 1 -a 1 -c 1 -g 1 -b packed:1  '--smpiargs=-x PAMI_DISABLE_CUDA_HOOK=1 -disable_gpu_hooks' nvprof --profile-from-start off ./sptrsv -d 0 -rhs $nrhs -forward -${FORMAT} ${INPUT_DIR}/$MAT 
#jsrun -n 1 -a 1 -c 1 -g 1 -b packed:1 ./sptrsv -d 0 -rhs 1 -forward -mtx ${INPUT_DIR}/$MAT 

done
