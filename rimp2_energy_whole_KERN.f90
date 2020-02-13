!  Copyright (C) 2020, Argonne National Laboratory. All Rights Reserved.
!  Licensed under the NCSA open source license

      module rimp2_shared
      use omp_lib
      #if defined(CUBLAS) || defined(CUBLASXT)
        use cublasf
      #endif
      ! mpi stuff
      integer:: ME, NPROC
      logical:: MASWRK

      #if defined(CUBLAS) || defined(CUBLASXT)
        integer(c_int)   :: cublas_return
        type(c_ptr)      :: cublas_handle
        #if defined(CUBLASXT)
          integer(c_int),dimension(1) :: cublasXt_deviceId
        #endif
      #endif

      end !*************************************************************


      program mp2CorrEng
      use rimp2_shared
      implicit double precision(a-h,o-z)

      ! energy var
      double precision:: E2, E2_mpi

      ! var dec
      character(80) :: filename,tmp
      double precision,allocatable,dimension(:) :: EIG
      double precision,allocatable,dimension(:,:) :: eij,eab,B32

      ! timing
      double precision:: dt_mpi, dt_min, dt_max, dt_mean


      #if !defined(NOMPI)
        ! mpi init
        include 'mpif.h'
        call MPI_INIT(ierror)
        call MPI_COMM_SIZE(MPI_COMM_WORLD, NPROC, ierror)
        call MPI_COMM_RANK(MPI_COMM_WORLD, ME, ierror)
      #else
        NPROC=1
        ME=0
      #endif
      MASWRK=ME.eq.0


      if(MASWRK) THEN
      #ifdef CPU
        write(*,*) 'You are running the code with CPU OpenMP'
      #elif defined(NVBLAS)
        write(*,*) 'You are running the code with nvblas on GPU'
      #elif defined(CUBLAS)
        write(*,*) 'You are running the code with cublas on GPU'
      #elif defined(CUBLASXT)
        write(*,*) 'You are running the code with cublasxt on GPU'
      #else
        write(*,*) 'You are running the code serially'
      #endif
      endif

      #if defined(CUBLAS)
        cublas_return = cublascreate_v2(cublas_handle)
      #elif defined(CUBLASXT)
        cublas_return = cublasXtcreate(cublas_handle)
        cublasXt_deviceId(1) = 0      ! only for one GPU
        cublas_return = cublasXtDeviceSelect(cublas_handle, 1, cublasXt_deviceId)  ! only for one GPU
        cublas_return = cublasXtSetBlockDim(cublas_handle, 2048)
      #endif

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!!!!!!!!!!! read input for gpu kernel !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

      ! input file name
      call get_command_argument(1,filename)

      ! open input file
      open(unit=500, file=filename,status='old',form="unformatted", &
      #if defined(INTEL)
             access='direct',recl=10,iostat=ierr,action='read')
      #else
             access='direct',recl=40,iostat=ierr,action='read')
      #endif

      ! read parameters
      read(500,iostat=ierr,rec=1) NAUXBASD
      read(500,iostat=ierr,rec=2) NCOR
      read(500,iostat=ierr,rec=3) NACT
      read(500,iostat=ierr,rec=4) NVIR
      read(500,iostat=ierr,rec=5) NBF

      ! write MO energy
      ALLOCATE(EIG(NBF))
      do ii=1,NBF
        irec=ii+5
        read(500,iostat=ierr,rec=irec) EIG(ii)
      enddo

      ! read B32
      ALLOCATE(B32(NAUXBASD*NVIR,NACT))
      jrec=irec
      do iact=1,NACT
        do ixvrt=1,NAUXBASD*NVIR
          jrec=jrec+1
          read(500,iostat=ierr,rec=jrec) B32(ixvrt,iact)
        enddo
      enddo
      ! read mp2 corr energy
      read(500,iostat=ierr,rec=jrec+1) E2_ref

!!!!!!!!!!! finish reading input for gpu kernel !!!!!!!!!!!!!!!!!!!!!!!
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

      IF (command_argument_count().gt.1) then
        call get_command_argument(2,tmp)
        read(tmp,*) NQVV
      ELSE
        NQVV=NACT
      ENDIF

      if(MASWRK) THEN
        write(*,'(5x,A,I10)') 'NQVV =',NQVV
        write(*,'(5x,A)') 'Memory Footprint:'
        write(*,'(10x,A4,I7,A,I5,A,F11.4,A)') 'B32(',NAUXBASD*NVIR,',',NACT,') = ',NAUXBASD*NVIR*NACT*8.D-6,' MB'
        write(*,'(10x,A4,I7,A,I5,A,F11.4,A)') 'eij(',NACT,',',NACT,') = ',NACT*NACT*8.D-6,' MB'
        write(*,'(10x,A4,I7,A,I5,A,F11.4,A)') 'eab(',NVIR,',',NVIR,') = ',NVIR*NVIR*8.D-6,' MB'
        write(*,'(10x,A4,I4,A,I3,A,I4,A,F11.4,A)') 'QVV(',NVIR,',',NACT,',',NVIR,') = ',NVIR*NACT*NVIR*8.D-6,' MB'
      endif

      ! some parameters
      NOCC=NCOR+NACT

      ! eliminate extra ranks when NPROC > NACT
      IF(ME.GT.NACT-1) then
        write(*,*) "rank skipped wwww", ME
        GOTO 120
      endif

      ! virt-virt MO energy pairs
      ALLOCATE(eab(NVIR,NVIR))
      DO IB=1,NVIR
        DO IA=1,IB
          eab(IA,IB) = EIG(IA+NOCC) + EIG(IB+NOCC)
          eab(IB,IA) = eab(IA,IB)
        ENDDO
      ENDDO

      ! occ-occ MO energy pairs
      ALLOCATE(eij(NACT,NACT))
      DO JJ=1,NACT
        DO II=1,JJ
          eij(II,JJ)=EIG(II+NCOR) + EIG(JJ+NCOR)
        ENDDO
      ENDDO

      ! trapezoidal decomposition occ-occ pairs
      CALL RIMP2_TRAPE_DEC(LddiActStart,LddiActEnd,NACT)

      ! Warming up
      E2_mpi=0.0D0
      ! corr energy accumulation
      CALL RIMP2_ENERGY_WHOLE(E2_mpi,B32,eij,eab,         &
           LddiActStart,LddiActEnd,NAUXBASD,NACT,NVIR,NQVV)

      ! Actual computation
      ! init E2_mpi
      E2_mpi=0.0D00

      ! tic
      st=omp_get_wtime()

      ! corr energy accumulation
      CALL RIMP2_ENERGY_WHOLE(E2_mpi,B32, eij,eab,        &
           LddiActStart,LddiActEnd,NAUXBASD,NACT,NVIR,NQVV)

      ! toc
      et=omp_get_wtime()
      dt_mpi = et - st

      #if defined(CUBLAS)
        cublas_return = cublasdestroy_v2(cublas_handle)
      #elif defined(CUBLASXT)                  
        cublas_return = cublasXtdestroy(cublas_handle)
      #endif

  120 CONTINUE


      #if !defined(NOMPI)
        E2=0.0D00
        call MPI_REDUCE(E2_mpi,E2,1,MPI_DOUBLE_PRECISION,MPI_SUM,0,MPI_COMM_WORLD,ierr) 
        dt_mean = 0.0D0
        dt_min = 0.0D0
        dt_max = 0.0D0
        call MPI_REDUCE(dt_mpi,dt_min,1,MPI_DOUBLE_PRECISION,MPI_MIN,0,MPI_COMM_WORLD,ierr)
        call MPI_REDUCE(dt_mpi,dt_max,1,MPI_DOUBLE_PRECISION,MPI_MAX,0,MPI_COMM_WORLD,ierr)
        call MPI_REDUCE(dt_mpi,dt_mean,1,MPI_DOUBLE_PRECISION,MPI_SUM,0,MPI_COMM_WORLD,ierr)
        dt_mean = dt_mean/NPROC
      #else
        E2=E2_mpi
        dt_min = dt_mpi
        dt_max = dt_mpi
        dt_mean = dt_mpi
      #endif

      if(MASWRK) THEN
        ediff=E2-E2_ref
        Rel_E2_error=abs(ediff/E2_ref)
        write(*,'(/,5X,A)') "Results:"
        write(*,'(10X,A45,I5)') "Number of MPI ranks   = ", NPROC
        write(*,'(10X,A45,I5)') "Number of OMP threads = ", omp_get_max_threads()
        ! write(*,'(10X,A45,E12.5)') "Computed  MP2 corr. energy = ", E2
        ! write(*,'(10X,A45,E12.5)') "Reference MP2 corr. energy = ", E2_ref
        write(*,'(10X,A45,E12.5)') "Rel. error of computed MP2 corr. energy = ", Rel_E2_error
        write(*,'(10X,A45,F8.3,A)') "Wall time (minimum)   = ", dt_min," sec"
        write(*,'(10X,A45,F8.3,A)') "Wall time (mean)      = ", dt_mean," sec"
        write(*,'(10X,A45,F8.3,A)') "Wall time (maximum)   = ", dt_max," sec"
        if(Rel_E2_error.le.1.0D-6) then
           write(*,'(10X,A)') "Passed :-) "
        else
           write(*,'(10X,A)') "Failed :-("
        endif
      endif

      #if !defined(NOMPI)
        call MPI_FINALIZE(ierr)
      #endif

      END !*************************************************************



      SUBROUTINE RIMP2_TRAPE_DEC(Istart,Iend,N)
      use rimp2_shared
      implicit double precision(a-h,o-z)

      IF(N .LE. NPROC) THEN
        Istart = ME + 1
        Iend = ME + 1
        RETURN
      ENDIF

      TOT = (N*(N+1)) / NPROC 
      Start = 1.0
      Istart=nint(Start)
      DO II = 0,ME
        TMP = TOT + Start*Start - Start
        End = (SQRT(4*TMP + 1.0) - 1.0)/2.0
        Iend=nint(End)
        IF(II.LT.ME) Start = End + 1
        Istart=nint(Start)
      ENDDO

      END !*************************************************************



      SUBROUTINE RIMP2_ENERGY_WHOLE(E2,B32,eij,eab,             &
                 LddiActStart,LddiActEnd,NAUXBASD,NACT,NVIR,NQVV)
      use rimp2_shared
      implicit double precision(a-h,o-z)

      ! output
      double precision :: E2

      ! input
      double precision :: eij(NACT,NACT)
      double precision :: eab(NVIR,NVIR)
      double precision :: B32(NAUXBASD*NVIR,NACT)

      ! local data
      double precision,save :: E2_omp
      double precision,allocatable,dimension(:,:,:),save :: QVV
      #ifdef CPU
        !$omp threadprivate(E2_omp,QVV)
      #endif

      ! turn off dynamics threadss
      CALL OMP_SET_DYNAMIC(.FALSE.)

      #ifdef CPU
        ! env num threads
        Nthreads=omp_get_max_threads()

        !$OMP PARALLEL NUM_THREADS(Nthreads)                              &
        !$omp default(none)                                               &
        !$omp shared(LddiActStart,LddiActEnd,                             &   
        !$omp        NACT,NVIR,NAUXBASD,B32,eij,eab,E2,NQVV)              &
        !$omp private(IACT,JACT,iQVV,IACTmod)
      #endif

      E2_omp = 0.0D00
      ALLOCATE(QVV(NVIR,NQVV,NVIR))

      #if defined(NVBLAS) || defined(CUBLAS) || defined(CUBLASXT)
        !$omp target enter data map(alloc: QVV) 
        !$omp target enter data map(to: eij,eab,B32) 
      #endif

      #ifdef CPU
        !$omp do schedule(DYNAMIC)
      #endif
      DO JACT=LddiActStart,LddiActEnd
        DO IACTmod=1,(JACT-1)/NQVV+1
          IACT = (IACTmod-1)*NQVV+1
          IF(IACTmod*NQVV>JACT) THEN
            iQVV = JACT-(IACTmod-1)*NQVV
          ELSE
            iQVV = NQVV
          ENDIF

          CALL RIMP2_ENERGYIJ(E2_omp, B32(1,IACT),B32(1,JACT),           &
                 eij,eab, QVV,IACT,JACT,NACT, NVIR,NAUXBASD,iQVV)

        ENDDO
      ENDDO
      #ifdef CPU
        !$omp end do
      #endif

      #if defined(NVBLAS) || defined(CUBLAS) || defined(CUBLASXT)
        !$omp target exit data map(release: QVV,eij,eab,B32) 
      #endif

      #ifdef CPU
        !$omp atomic
      #endif
      E2 = E2 + E2_omp

      DEALLOCATE(QVV)

      #ifdef CPU
        !$OMP END PARALLEL
      #endif

      END !*************************************************************




      SUBROUTINE RIMP2_ENERGYIJ(E2,BI,BJ,eij,eab,                     &
                 QVV,IACT,JACT,NACT,NVIR,NAUXBASD,iQVV)
      use rimp2_shared
      implicit double precision(a-h,o-z)

      ! output
      double precision :: E2

      ! input
      double precision :: BI(NAUXBASD*NVIR*iQVV)
      double precision :: BJ(NAUXBASD*NVIR)
      double precision :: eab(NVIR,NVIR)
      double precision :: eij(NACT,NACT)

      ! buffer
      double precision :: QVV(NVIR,iQVV,NVIR)


      #if defined(NVBLAS) || defined(CUBLAS) || defined(CUBLASXT)
        !$omp target data use_device_ptr(BI,BJ,QVV)
      #endif
      #if defined(CUBLAS) || defined(CUBLASXT)
        #if defined(CUBLAS)
          cublas_return =  CUBLASDGEMM_v2 &
        #elif defined(CUBLASXT)
          cublas_return =  cublasXtDgemm  &
        #endif
                   (cublas_handle,CUBLAS_OP_T,CUBLAS_OP_N,              &
                     NVIR*iQVV,NVIR,NAUXBASD,                           &
                  1.0D00, BI,NAUXBASD,                                  &
                          BJ,NAUXBASD,                                  &
                  0.0D00, QVV,NVIR*iQVV)
        cublas_return = cudaDeviceSynchronize()

      #else
        CALL DGEMM &
           ('T','N',  &
                     NVIR*iQVV,NVIR,NAUXBASD,                           &
                  1.0D00, BI,NAUXBASD,                                  &
                          BJ,NAUXBASD,                                  &
                  0.0D00, QVV,NVIR*iQVV)
      #endif

      #if defined(NVBLAS) || defined(CUBLAS) || defined(CUBLASXT)
        !$omp end target data
      #endif

      #if defined(NVBLAS) || defined(CUBLAS) || defined(CUBLASXT)
        !$omp target map(tofrom:E2)
        !$omp teams distribute reduction(+:E2) 
      #endif
      DO IC=1,iQVV
        E2_t = 0.0D00
        #if defined(NVBLAS) || defined(CUBLAS) || defined(CUBLASXT)
          !$omp parallel do reduction(+:E2_t) collapse(2)
        #endif
        DO IB=1,NVIR
          DO IA=1,NVIR
            Tijab=QVV(IA,IC,IB)/(eij(IACT+IC-1,JACT)-eab(IA,IB))
            Q_t=QVV(IA,IC,IB)+QVV(IA,IC,IB)
            E2_t=E2_t + Tijab*(Q_t-QVV(IB,IC,IA))
          ENDDO
        ENDDO
        #if defined(NVBLAS) || defined(CUBLAS) || defined(CUBLASXT)
          !$omp end parallel do
        #endif
         FAC=2.0D00
         IF(IACT+IC-1.EQ.JACT) FAC=1.0D00
         E2 = E2 + FAC*E2_t
      ENDDO
      #if defined(NVBLAS) || defined(CUBLAS) || defined(CUBLASXT)
        !$omp end teams distribute
        !$omp end target
      #endif

      END



