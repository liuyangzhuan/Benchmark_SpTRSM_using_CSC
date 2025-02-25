#include "common.h"
#include "mmio_highlevel.h"
#include "utils.h"
#include "tranpose.h"
#include "findlevel.h"

#include "sptrsv_syncfree_serialref.h"
#include "sptrsv_syncfree_cuda.h"



void
dreadtriple_dist(FILE *fp, int *m, int *n, int *nonz,
	    double **nzval, int **rowind, int **colptr)
{
    int    j, k, jsize, nnz, nz, new_nonz;
    double *a, *val;
    int    *asub, *xa, *row, *col;
    int    zero_base = 0;
    
    /* 	File format:
     *    First line:  #rows    #non-zero
     *    Triplet in the rest of lines:
     *                 row    col    value
     */
    fscanf(fp, "%d%d%d", m, n, nonz);
    new_nonz = *nonz;

    *m = *n;
    *nzval    = (double *) malloc(new_nonz* sizeof(double));
    *rowind = (int *) malloc(new_nonz* sizeof(int));
    *colptr   = (int *) malloc((*n+1)* sizeof(int));
		
	a    = *nzval;
    asub = *rowind;
    xa   = *colptr;

    val = (double *) malloc(new_nonz * sizeof(double)); 
    row = (int *) malloc(new_nonz * sizeof(int));
    col = (int *) malloc(new_nonz * sizeof(int));

    for (j = 0; j < *n; ++j) xa[j] = 0;

    /* Read into the triplet array from a file */
    for (nnz = 0, nz = 0; nnz < *nonz; ++nnz) {

	fscanf(fp, "%d%d%lf\n", &row[nz], &col[nz], &val[nz]);

	if ( nnz == 0 ) /* first nonzero */
	    if ( row[0] == 0 || col[0] == 0 ) {
		zero_base = 1;
		printf("triplet file: row/col indices are zero-based.\n");
	    } else
		printf("triplet file: row/col indices are one-based.\n");

	if ( !zero_base ) {
	    /* Change to 0-based indexing. */
	    --row[nz];
	    --col[nz];
	}

	if (row[nz] < 0 || row[nz] >= *m || col[nz] < 0 || col[nz] >= *n) {
	    fprintf(stderr, "nz " "%5d" ", (" "%5d" ", " "%5d" ") = %e out of bound, removed\n", nz, row[nz], col[nz], val[nz]);
	    exit(-1);
	} else {
	    ++xa[col[nz]];	
	    ++nz;
	}
    }

    *nonz = nz;

    /* Initialize the array of column pointers */
    k = 0;
    jsize = xa[0];
    xa[0] = 0;
    for (j = 1; j < *n; ++j) {
	k += jsize;
	jsize = xa[j];
	xa[j] = k;
    }
    
    /* Copy the triplets into the column oriented storage */
    for (nz = 0; nz < *nonz; ++nz) {
	j = col[nz];
	k = xa[j];
	asub[k] = row[nz];
	a[k] = val[nz];
	++xa[j];
    }

    /* Reset the column pointers to the beginning of each column */
    for (j = *n; j > 0; --j)
	xa[j] = xa[j-1];
    xa[0] = 0;

    free(val);
    free(row);
    free(col);
}


int main(int argc, char ** argv)
{
    // report precision of floating-point
    printf("---------------------------------------------------------------------------------------------\n");
    char  *precision;
    if (sizeof(VALUE_TYPE) == 4)
    {
        precision = (char *)"32-bit Single Precision";
    }
    else if (sizeof(VALUE_TYPE) == 8)
    {
        precision = (char *)"64-bit Double Precision";
    }
    else
    {
        printf("Wrong precision. Program exit!\n");
        return 0;
    }

    printf("PRECISION = %s\n", precision);
    printf("Benchmark REPEAT = %i\n", BENCH_REPEAT);
    printf("---------------------------------------------------------------------------------------------\n");

    int m, n, nnzA, isSymmetricA;
    int *csrRowPtrA;
    int *csrColIdxA;
    VALUE_TYPE *csrValA;

    int nnzTR;
    int *cscRowIdxTR;
    int *cscColPtrTR;
    VALUE_TYPE *cscValTR;

    int device_id = 0;
    int rhs = 0;
    int substitution = SUBSTITUTION_FORWARD;

    // "Usage: ``./sptrsv -d 0 -rhs 1 -forward -mtx A.mtx'' for LX=B on device 0"
    int argi = 1;

    // load device id
    char *devstr;
    if(argc > argi)
    {
        devstr = argv[argi];
        argi++;
    }

    if (strcmp(devstr, "-d") != 0) return 0;

    if(argc > argi)
    {
        device_id = atoi(argv[argi]);
        argi++;
    }
    printf("device_id = %i\n", device_id);

    // load the number of right-hand-side
    char *rhsstr;
    if(argc > argi)
    {
        rhsstr = argv[argi];
        argi++;
    }

    if (strcmp(rhsstr, "-rhs") != 0) return 0;

    if(argc > argi)
    {
        rhs = atoi(argv[argi]);
        argi++;
    }
    printf("rhs = %i\n", rhs);

    // load substitution, forward or backward
    char *substitutionstr;
    if(argc > argi)
    {
        substitutionstr = argv[argi];
        argi++;
    }

    if (strcmp(substitutionstr, "-forward") == 0)
        substitution = SUBSTITUTION_FORWARD;
    else if (strcmp(substitutionstr, "-backward") == 0)
        substitution = SUBSTITUTION_BACKWARD;
    printf("substitutionstr = %s\n", substitutionstr);
    printf("substitution = %i\n", substitution);

    // load matrix file type, mtx, cscl, or cscu
    char *matstr;
    if(argc > argi)
    {
        matstr = argv[argi];
        argi++;
    }
    printf("matstr = %s\n", matstr);

    // load matrix data from file
    char  *filename;
    if(argc > argi)
    {
        filename = argv[argi];
        argi++;
    }
    printf("-------------- %s --------------\n", filename);

    srand(time(NULL));
    if (strcmp(matstr, "-mtx") == 0)
    {
        // load mtx data to the csr format
        mmio_info(&m, &n, &nnzA, &isSymmetricA, filename);
        csrRowPtrA = (int *)malloc((m+1) * sizeof(int));
        csrColIdxA = (int *)malloc(nnzA * sizeof(int));
        csrValA    = (VALUE_TYPE *)malloc(nnzA * sizeof(VALUE_TYPE));
        mmio_data(csrRowPtrA, csrColIdxA, csrValA, filename);
        printf("input matrix A: ( %i, %i ) nnz = %i\n", m, n, nnzA);

        // extract L or U with a unit diagonal of A
        int *csrRowPtr_tmp = (int *)malloc((m+1) * sizeof(int));
        int *csrColIdx_tmp = (int *)malloc((m+nnzA) * sizeof(int));
        VALUE_TYPE *csrVal_tmp    = (VALUE_TYPE *)malloc((m+nnzA) * sizeof(VALUE_TYPE));

        int nnz_pointer = 0;
        csrRowPtr_tmp[0] = 0;
        for (int i = 0; i < m; i++)
        {
            for (int j = csrRowPtrA[i]; j < csrRowPtrA[i+1]; j++)
            {   
                if (substitution == SUBSTITUTION_FORWARD)
                {
                    if (csrColIdxA[j] < i)
                    {
                        csrColIdx_tmp[nnz_pointer] = csrColIdxA[j];
                        csrVal_tmp[nnz_pointer] = rand() % 10 + 1; //csrValA[j]; 
                        nnz_pointer++;
                    }
                }
                else if (substitution == SUBSTITUTION_BACKWARD)
                {
                    if (csrColIdxA[j] > i)
                    {
                        csrColIdx_tmp[nnz_pointer] = csrColIdxA[j];
                        csrVal_tmp[nnz_pointer] = rand() % 10 + 1; //csrValA[j]; 
                        nnz_pointer++;
                    }
                }
            }

            // add dia nonzero
            csrColIdx_tmp[nnz_pointer] = i;
            csrVal_tmp[nnz_pointer] = 1.0;
            nnz_pointer++;

            csrRowPtr_tmp[i+1] = nnz_pointer;
        }

        int nnz_tmp = csrRowPtr_tmp[m];
        nnzTR = nnz_tmp;

        if (substitution == SUBSTITUTION_FORWARD)
            printf("A's unit-lower triangular L: ( %i, %i ) nnz = %i\n", m, n, nnzTR);
        else if (substitution == SUBSTITUTION_BACKWARD)
            printf("A's unit-upper triangular U: ( %i, %i ) nnz = %i\n", m, n, nnzTR);

        csrColIdx_tmp = (int *)realloc(csrColIdx_tmp, sizeof(int) * nnzTR);
        csrVal_tmp = (VALUE_TYPE *)realloc(csrVal_tmp, sizeof(VALUE_TYPE) * nnzTR);

        cscRowIdxTR = (int *)malloc(nnzTR * sizeof(int));
        cscColPtrTR = (int *)malloc((n+1) * sizeof(int));
        memset(cscColPtrTR, 0, (n+1) * sizeof(int));
        cscValTR    = (VALUE_TYPE *)malloc(nnzTR * sizeof(VALUE_TYPE));

        // transpose from csr to csc
        matrix_transposition(m, n, nnzTR,
                             csrRowPtr_tmp, csrColIdx_tmp, csrVal_tmp,
                             cscRowIdxTR, cscColPtrTR, cscValTR);

        // keep each column sort 
        for (int i = 0; i < n; i++)
        {
            quick_sort_key_val_pair<int, int>(&cscRowIdxTR[cscColPtrTR[i]],
                                              &cscRowIdxTR[cscColPtrTR[i]],
                                              cscColPtrTR[i+1]-cscColPtrTR[i]);
        }

        // check unit diagonal
        int dia_miss = 0;
        for (int i = 0; i < n; i++)
        {
            bool miss;
            if (substitution == SUBSTITUTION_FORWARD)
                miss = cscRowIdxTR[cscColPtrTR[i]] != i;
            else if (substitution == SUBSTITUTION_BACKWARD)
                cscRowIdxTR[cscColPtrTR[i+1] - 1] != i;

            if (miss) dia_miss++;
        }
        //printf("dia miss = %i\n", dia_miss);
        if (dia_miss != 0) 
        {
            printf("This matrix has incomplete diagonal, #missed dia nnz = %i\n", dia_miss); 
            return;
        }

        free(csrColIdx_tmp);
        free(csrVal_tmp);
        free(csrRowPtr_tmp);

        free(csrColIdxA);
        free(csrValA);
        free(csrRowPtrA);
    }
    else if (strcmp(matstr, "-csc") == 0)
    {
        FILE *f;
        int returnvalue;

        if ((f = fopen(filename, "r")) == NULL)
            return -1;

        returnvalue = fscanf(f, "%d", &m);
        returnvalue = fscanf(f, "%d", &n);
        returnvalue = fscanf(f, "%d", &nnzTR);

        cscColPtrTR = (int *)malloc((n+1) * sizeof(int));
        memset(cscColPtrTR, 0, (n+1) * sizeof(int));
        cscRowIdxTR = (int *)malloc(nnzTR * sizeof(int));
        cscValTR    = (VALUE_TYPE *)malloc(nnzTR * sizeof(VALUE_TYPE));

        // read row idx
        for (int i = 0; i < n+1; i++)
        {
            returnvalue = fscanf(f, "%d", &cscColPtrTR[i]);
            cscColPtrTR[i]--; // from 1-based to 0-based
        }

        // read col idx
        for (int i = 0; i < nnzTR; i++)
        {
            returnvalue = fscanf(f, "%d", &cscRowIdxTR[i]);
            cscRowIdxTR[i]--; // from 1-based to 0-based
        }

        // read val
        for (int i = 0; i < nnzTR; i++)
        {
            cscValTR[i] = rand() % 10 + 1;
            //returnvalue = fscanf(f, "%lg", &cscValTR[i]);
        }

        if (f != stdin)
            fclose(f);

        // keep each column sort 
        for (int i = 0; i < n; i++)
        {
            quick_sort_key_val_pair<int, int>(&cscRowIdxTR[cscColPtrTR[i]],
                                              &cscRowIdxTR[cscColPtrTR[i]],
                                              cscColPtrTR[i+1]-cscColPtrTR[i]);
        }

        if (substitution == SUBSTITUTION_FORWARD)
            printf("Input csc unit-lower triangular L: ( %i, %i ) nnz = %i\n", m, n, nnzTR);
        else if (substitution == SUBSTITUTION_BACKWARD)
            printf("Input csc unit-upper triangular U: ( %i, %i ) nnz = %i\n", m, n, nnzTR);
       
        // check unit diagonal
        int dia_miss = 0;
        for (int i = 0; i < n; i++)
        {
            bool miss;
            if (substitution == SUBSTITUTION_FORWARD)
                miss = cscRowIdxTR[cscColPtrTR[i]] != i;
            else if (substitution == SUBSTITUTION_BACKWARD)
                cscRowIdxTR[cscColPtrTR[i+1] - 1] != i;

            if (miss) dia_miss++;
        }
        //printf("dia miss = %i\n", dia_miss);
        if (dia_miss != 0) 
        {
            printf("This matrix has incomplete diagonal, #missed dia nnz = %i\n", dia_miss); 
            return;
        }
    }else if (strcmp(matstr, "-dat") == 0)
    {
        FILE *f;
        int returnvalue;

        if ((f = fopen(filename, "r")) == NULL)
            return -1;

        // returnvalue = fscanf(f, "%d", &m);
        // returnvalue = fscanf(f, "%d", &n);
        // returnvalue = fscanf(f, "%d", &nnzTR);

        // cscColPtrTR = (int *)malloc((n+1) * sizeof(int));
        // memset(cscColPtrTR, 0, (n+1) * sizeof(int));
        // cscRowIdxTR = (int *)malloc(nnzTR * sizeof(int));
        // cscValTR    = (VALUE_TYPE *)malloc(nnzTR * sizeof(VALUE_TYPE));

        // // read row idx
        // for (int i = 0; i < n+1; i++)
        // {
            // returnvalue = fscanf(f, "%d", &cscColPtrTR[i]);
            // cscColPtrTR[i]--; // from 1-based to 0-based
        // }

        // // read col idx
        // for (int i = 0; i < nnzTR; i++)
        // {
            // returnvalue = fscanf(f, "%d", &cscRowIdxTR[i]);
            // cscRowIdxTR[i]--; // from 1-based to 0-based
        // }

        // // read val
        // for (int i = 0; i < nnzTR; i++)
        // {
            // cscValTR[i] = rand() % 10 + 1;
            // //returnvalue = fscanf(f, "%lg", &cscValTR[i]);
        // }		
		
		
		dreadtriple_dist(f, &m, &n, &nnzTR, &cscValTR, &cscRowIdxTR, &cscColPtrTR);
		

        if (f != stdin)
            fclose(f);

        // keep each column sort 
        for (int i = 0; i < n; i++)
        {
            quick_sort_key_val_pair<int, int>(&cscRowIdxTR[cscColPtrTR[i]],
                                              &cscRowIdxTR[cscColPtrTR[i]],
                                              cscColPtrTR[i+1]-cscColPtrTR[i]);
        }

        if (substitution == SUBSTITUTION_FORWARD)
            printf("Input csc unit-lower triangular L: ( %i, %i ) nnz = %i\n", m, n, nnzTR);
        else if (substitution == SUBSTITUTION_BACKWARD)
            printf("Input csc unit-upper triangular U: ( %i, %i ) nnz = %i\n", m, n, nnzTR);
       
        // check unit diagonal
        int dia_miss = 0;
        for (int i = 0; i < n; i++)
        {
            bool miss;
            if (substitution == SUBSTITUTION_FORWARD)
                miss = cscRowIdxTR[cscColPtrTR[i]] != i;
            else if (substitution == SUBSTITUTION_BACKWARD)
                cscRowIdxTR[cscColPtrTR[i+1] - 1] != i;

            if (miss) dia_miss++;
        }
        //printf("dia miss = %i\n", dia_miss);
        if (dia_miss != 0) 
        {
            printf("This matrix has incomplete diagonal, #missed dia nnz = %i\n", dia_miss); 
            return;
        }
    }	

    // find level sets
    int nlevel = 0;
    int parallelism_min = 0;
    int parallelism_avg = 0;
    int parallelism_max = 0;
    findlevel_csc(cscColPtrTR, cscRowIdxTR, cscValTR, m, n, nnzTR, &nlevel,
                  &parallelism_min, &parallelism_avg, &parallelism_max);
    double fparallelism = (double)m/(double)nlevel;
    printf("This matrix/graph has %i levels, its parallelism is %4.2f (min: %i ; avg: %i ; max: %i )\n", 
           nlevel, fparallelism, parallelism_min, parallelism_avg, parallelism_max);

    // x and b are all row-major
    VALUE_TYPE *x_ref = (VALUE_TYPE *)malloc(sizeof(VALUE_TYPE) * n * rhs);
    for ( int i = 0; i < n; i++)
        for (int j = 0; j < rhs; j++)
            x_ref[i * rhs + j] = rand() % 10 + 1; //j + 1;

    VALUE_TYPE *b = (VALUE_TYPE *)malloc(sizeof(VALUE_TYPE) * m * rhs);
    VALUE_TYPE *x = (VALUE_TYPE *)malloc(sizeof(VALUE_TYPE) * n * rhs);

    for (int i = 0; i < m * rhs; i++)
        b[i] = 0;

    for (int i = 0; i < n * rhs; i++)
        x[i] = 0;

    // run csc spmv to generate b
    for (int i = 0; i < n; i++)
    {
        for (int j = cscColPtrTR[i]; j < cscColPtrTR[i+1]; j++)
        {
            int rowid = cscRowIdxTR[j]; //printf("rowid = %i\n", rowid);
            for (int k = 0; k < rhs; k++)
            {
                b[rowid * rhs + k] += cscValTR[j] * x_ref[i * rhs + k];
            }
        }
    }

    // run serial syncfree SpTRSV as a reference
    printf("---------------------------------------------------------------------------------------------\n");
    sptrsv_syncfree_serialref(cscColPtrTR, cscRowIdxTR, cscValTR, m, n, nnzTR,
                              substitution, rhs, x, b, x_ref);

    // set device
    cudaSetDevice(device_id);
    cudaDeviceProp deviceProp;
    cudaGetDeviceProperties(&deviceProp, device_id);

    printf("---------------------------------------------------------------------------------------------\n");
    printf("Device [ %i ] %s @ %4.2f MHz\n", device_id, deviceProp.name, deviceProp.clockRate * 1e-3f);

    // run cuda syncfree SpTRSV or SpTRSM

    printf("---------------------------------------------------------------------------------------------\n");
    double gflops_autotuned = 0;
    sptrsv_syncfree_cuda(cscColPtrTR, cscRowIdxTR, cscValTR, m, n, nnzTR,
                         substitution, rhs, OPT_WARP_AUTO, x, b, x_ref, &gflops_autotuned);

    printf("---------------------------------------------------------------------------------------------\n");

    // done!
    free(cscRowIdxTR);
    free(cscColPtrTR);
    free(cscValTR);

    free(x);
    free(x_ref);
    free(b);

    return 0;
}
