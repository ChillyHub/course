#include <cstdio>
#include <vector>
#include <cuda_runtime.h>
#include "helper_cuda.h"
#include "helper_math.h"
#include "CudaArray.cuh"
#include "ticktock.h"
#include "writevdb.h"
#include <thread>

__global__ void advect_kernel(CudaTextureAccessor<float4> texVel, CudaSurfaceAccessor<float4> sufLoc, CudaSurfaceAccessor<char> sufBound, unsigned int n) {
    int x = threadIdx.x + blockDim.x * blockIdx.x;
    int y = threadIdx.y + blockDim.y * blockIdx.y;
    int z = threadIdx.z + blockDim.z * blockIdx.z;
    if (x >= n || y >= n || z >= n) return;

    auto sample = [] (CudaTextureAccessor<float4> tex, float3 loc) -> float3 {
        float4 vel = tex.sample(loc.x, loc.y, loc.z);
        return make_float3(vel.x, vel.y, vel.z);
    };

    float3 loc = make_float3(x + 0.5f, y + 0.5f, z + 0.5f);
    if (sufBound.read(x, y, z) >= 0) {
        float3 vel1 = sample(texVel, loc);
        float3 vel2 = sample(texVel, loc - 0.5f * vel1);
        float3 vel3 = sample(texVel, loc - 0.75f * vel2);
        loc -= (2.f / 9.f) * vel1 + (1.f / 3.f) * vel2 + (4.f / 9.f) * vel3;
    }
    sufLoc.write(make_float4(loc.x, loc.y, loc.z, 0.f), x, y, z);
}

template <class T>
__global__ void resample_kernel(CudaSurfaceAccessor<float4> sufLoc, CudaTextureAccessor<T> texClr, CudaSurfaceAccessor<T> sufClrNext, unsigned int n) {
    int x = threadIdx.x + blockDim.x * blockIdx.x;
    int y = threadIdx.y + blockDim.y * blockIdx.y;
    int z = threadIdx.z + blockDim.z * blockIdx.z;
    if (x >= n || y >= n || z >= n) return;

    float4 loc = sufLoc.read(x, y, z);
    T clr = texClr.sample(loc.x, loc.y, loc.z);
    sufClrNext.write(clr, x, y, z);
}

__global__ void decay_kernel(CudaSurfaceAccessor<float> sufTmp, CudaSurfaceAccessor<float> sufTmpNext, CudaSurfaceAccessor<char> sufBound, float ambientRate, float decayRate, unsigned int n) {
    int x = threadIdx.x + blockDim.x * blockIdx.x;
    int y = threadIdx.y + blockDim.y * blockIdx.y;
    int z = threadIdx.z + blockDim.z * blockIdx.z;
    if (x >= n || y >= n || z >= n) return;
    if (sufBound.read(x, y, z) < 0) return;

    float txp = sufTmp.read<cudaBoundaryModeClamp>(x + 1, y, z);
    float typ = sufTmp.read<cudaBoundaryModeClamp>(x, y + 1, z);
    float tzp = sufTmp.read<cudaBoundaryModeClamp>(x, y, z + 1);
    float txn = sufTmp.read<cudaBoundaryModeClamp>(x - 1, y, z);
    float tyn = sufTmp.read<cudaBoundaryModeClamp>(x, y - 1, z);
    float tzn = sufTmp.read<cudaBoundaryModeClamp>(x, y, z - 1);
    float tmpAvg = (txp + typ + tzp + txn + tyn + tzn) * (1 / 6.f);
    float tmpNext = sufTmp.read(x, y, z);
    tmpNext = (tmpNext * ambientRate + tmpAvg * (1.f - ambientRate)) * decayRate;
    sufTmpNext.write(tmpNext, x, y, z);
}

__global__ void divergence_kernel(CudaSurfaceAccessor<float4> sufVel, CudaSurfaceAccessor<float> sufDiv, CudaSurfaceAccessor<char> sufBound, unsigned int n) {
    int x = threadIdx.x + blockDim.x * blockIdx.x;
    int y = threadIdx.y + blockDim.y * blockIdx.y;
    int z = threadIdx.z + blockDim.z * blockIdx.z;
    if (x >= n || y >= n || z >= n) return;
    if (sufBound.read(x, y, z) < 0) {
        sufDiv.write(0.f, x, y, z);
        return;
    }

    float vxp = sufVel.read<cudaBoundaryModeClamp>(x + 1, y, z).x;
    float vyp = sufVel.read<cudaBoundaryModeClamp>(x, y + 1, z).y;
    float vzp = sufVel.read<cudaBoundaryModeClamp>(x, y, z + 1).z;
    float vxn = sufVel.read<cudaBoundaryModeClamp>(x - 1, y, z).x;
    float vyn = sufVel.read<cudaBoundaryModeClamp>(x, y - 1, z).y;
    float vzn = sufVel.read<cudaBoundaryModeClamp>(x, y, z - 1).z;
    float div = (vxp - vxn + vyp - vyn + vzp - vzn) * 0.5f;
    sufDiv.write(div, x, y, z);
}

__global__ void sumloss_kernel(CudaSurfaceAccessor<float> sufDiv, float *sum, unsigned int n) {
    int x = threadIdx.x + blockDim.x * blockIdx.x;
    int y = threadIdx.y + blockDim.y * blockIdx.y;
    int z = threadIdx.z + blockDim.z * blockIdx.z;
    if (x >= n || y >= n || z >= n) return;

    float div = sufDiv.read(x, y, z);
    atomicAdd(sum, div * div);
}

/*__global__ void jacobi_kernel(CudaSurfaceAccessor<float> sufDiv, CudaSurfaceAccessor<float> sufPre, CudaSurfaceAccessor<float> sufPreNext, CudaSurfaceAccessor<char> sufBound, unsigned int n) {
    unsigned int x = threadIdx.x + blockDim.x * blockIdx.x;
    unsigned int y = threadIdx.y + blockDim.y * blockIdx.y;
    unsigned int z = threadIdx.z + blockDim.z * blockIdx.z;
    if (x >= n || y >= n || z >= n) return;
    if (sufBound.read(x, y, z) < 0) return;

    float pxp = sufPre.read<cudaBoundaryModeClamp>(x + 1, y, z);
    float pxn = sufPre.read<cudaBoundaryModeClamp>(x - 1, y, z);
    float pyp = sufPre.read<cudaBoundaryModeClamp>(x, y + 1, z);
    float pyn = sufPre.read<cudaBoundaryModeClamp>(x, y - 1, z);
    float pzp = sufPre.read<cudaBoundaryModeClamp>(x, y, z + 1);
    float pzn = sufPre.read<cudaBoundaryModeClamp>(x, y, z - 1);
    float div = sufDiv.read(x, y, z);
    float preNext = (pxp + pxn + pyp + pyn + pzp + pzn - div) * (1.f / 6.f);
    sufPreNext.write(preNext, x, y, z);
}*/

__global__ void heatup_kernel(CudaSurfaceAccessor<float4> sufVel, CudaSurfaceAccessor<float> sufTmp, CudaSurfaceAccessor<float> sufClr, CudaSurfaceAccessor<char> sufBound, float tmpAmbient, float heatRate, float clrRate, unsigned int n) {
    int x = threadIdx.x + blockDim.x * blockIdx.x;
    int y = threadIdx.y + blockDim.y * blockIdx.y;
    int z = threadIdx.z + blockDim.z * blockIdx.z;
    if (x >= n || y >= n || z >= n) return;
    if (sufBound.read(x, y, z) < 0) return;

    float4 vel = sufVel.read(x, y, z);
    float tmp = sufTmp.read(x, y, z);
    float clr = sufClr.read(x, y, z);
    vel.z += heatRate * (tmp - tmpAmbient);
    vel.z -= clrRate * clr;
    sufVel.write(vel, x, y, z);
}

__global__ void subgradient_kernel(CudaSurfaceAccessor<float> sufPre, CudaSurfaceAccessor<float4> sufVel, CudaSurfaceAccessor<char> sufBound, unsigned int n) {
    int x = threadIdx.x + blockDim.x * blockIdx.x;
    int y = threadIdx.y + blockDim.y * blockIdx.y;
    int z = threadIdx.z + blockDim.z * blockIdx.z;
    if (x >= n || y >= n || z >= n) return;
    if (sufBound.read(x, y, z) < 0) return;

    float pxn = sufPre.read<cudaBoundaryModeZero>(x - 1, y, z);
    float pyn = sufPre.read<cudaBoundaryModeZero>(x, y - 1, z);
    float pzn = sufPre.read<cudaBoundaryModeZero>(x, y, z - 1);
    float pxp = sufPre.read<cudaBoundaryModeZero>(x + 1, y, z);
    float pyp = sufPre.read<cudaBoundaryModeZero>(x, y + 1, z);
    float pzp = sufPre.read<cudaBoundaryModeZero>(x, y, z + 1);
    float4 vel = sufVel.read(x, y, z);
    vel.x -= (pxp - pxn) * 0.5f;
    vel.y -= (pyp - pyn) * 0.5f;
    vel.z -= (pzp - pzn) * 0.5f;
    sufVel.write(vel, x, y, z);
}

template <int phase>
__global__ void rbgs_kernel(CudaSurfaceAccessor<float> sufPre, CudaSurfaceAccessor<float> sufDiv, unsigned int n) {
    int x = threadIdx.x + blockDim.x * blockIdx.x;
    int y = threadIdx.y + blockDim.y * blockIdx.y;
    int z = threadIdx.z + blockDim.z * blockIdx.z;
    if (x >= n || y >= n || z >= n) return;
    if ((x + y + z) % 2 != phase) return;

    float pxp = sufPre.read<cudaBoundaryModeClamp>(x + 1, y, z);
    float pxn = sufPre.read<cudaBoundaryModeClamp>(x - 1, y, z);
    float pyp = sufPre.read<cudaBoundaryModeClamp>(x, y + 1, z);
    float pyn = sufPre.read<cudaBoundaryModeClamp>(x, y - 1, z);
    float pzp = sufPre.read<cudaBoundaryModeClamp>(x, y, z + 1);
    float pzn = sufPre.read<cudaBoundaryModeClamp>(x, y, z - 1);
    float div = sufDiv.read(x, y, z);
    float preNext = (pxp + pxn + pyp + pyn + pzp + pzn - div) * (1.f / 6.f);
    sufPre.write(preNext, x, y, z);
}

__global__ void residual_kernel(CudaSurfaceAccessor<float> sufRes, CudaSurfaceAccessor<float> sufPre, CudaSurfaceAccessor<float> sufDiv, unsigned int n) {
    int x = threadIdx.x + blockDim.x * blockIdx.x;
    int y = threadIdx.y + blockDim.y * blockIdx.y;
    int z = threadIdx.z + blockDim.z * blockIdx.z;
    if (x >= n || y >= n || z >= n) return;

    float pxp = sufPre.read<cudaBoundaryModeClamp>(x + 1, y, z);
    float pxn = sufPre.read<cudaBoundaryModeClamp>(x - 1, y, z);
    float pyp = sufPre.read<cudaBoundaryModeClamp>(x, y + 1, z);
    float pyn = sufPre.read<cudaBoundaryModeClamp>(x, y - 1, z);
    float pzp = sufPre.read<cudaBoundaryModeClamp>(x, y, z + 1);
    float pzn = sufPre.read<cudaBoundaryModeClamp>(x, y, z - 1);
    float pre = sufPre.read(x, y, z);
    float div = sufDiv.read(x, y, z);
    float res = pxp + pxn + pyp + pyn + pzp + pzn - 6.f * pre - div;
    sufRes.write(res, x, y, z);
}

__global__ void restrict_kernel(CudaSurfaceAccessor<float> sufPreNext, CudaSurfaceAccessor<float> sufPre, unsigned int n) {
    int x = threadIdx.x + blockDim.x * blockIdx.x;
    int y = threadIdx.y + blockDim.y * blockIdx.y;
    int z = threadIdx.z + blockDim.z * blockIdx.z;
    if (x >= n || y >= n || z >= n) return;

    float ooo = sufPre.read<cudaBoundaryModeClamp>(x*2, y*2, z*2);
    float ioo = sufPre.read<cudaBoundaryModeClamp>(x*2+1, y*2, z*2);
    float oio = sufPre.read<cudaBoundaryModeClamp>(x*2, y*2+1, z*2);
    float iio = sufPre.read<cudaBoundaryModeClamp>(x*2+1, y*2+1, z*2);
    float ooi = sufPre.read<cudaBoundaryModeClamp>(x*2, y*2, z*2+1);
    float ioi = sufPre.read<cudaBoundaryModeClamp>(x*2+1, y*2, z*2+1);
    float oii = sufPre.read<cudaBoundaryModeClamp>(x*2, y*2+1, z*2+1);
    float iii = sufPre.read<cudaBoundaryModeClamp>(x*2+1, y*2+1, z*2+1);
    float preNext = (ooo + ioo + oio + iio + ooi + ioi + oii + iii);
    sufPreNext.write(preNext, x, y, z);
}

__global__ void fillzero_kernel(CudaSurfaceAccessor<float> sufPre, unsigned int n) {
    int x = threadIdx.x + blockDim.x * blockIdx.x;
    int y = threadIdx.y + blockDim.y * blockIdx.y;
    int z = threadIdx.z + blockDim.z * blockIdx.z;
    if (x >= n || y >= n || z >= n) return;

    sufPre.write(0.f, x, y, z);
}

__global__ void prolongate_kernel(CudaSurfaceAccessor<float> sufPreNext, CudaSurfaceAccessor<float> sufPre, unsigned int n) {
    int x = threadIdx.x + blockDim.x * blockIdx.x;
    int y = threadIdx.y + blockDim.y * blockIdx.y;
    int z = threadIdx.z + blockDim.z * blockIdx.z;
    if (x >= n || y >= n || z >= n) return;

    float preDelta = sufPre.read(x, y, z) * (0.5f / 8.f);
#pragma unroll
    for (int dz = 0; dz < 2; dz++) {
#pragma unroll
        for (int dy = 0; dy < 2; dy++) {
#pragma unroll
            for (int dx = 0; dx < 2; dx++) {
                float preNext = sufPreNext.read<cudaBoundaryModeZero>(x*2+dx, y*2+dy, z*2+dz);
                preNext += preDelta;
                sufPreNext.write<cudaBoundaryModeZero>(preNext, x*2+dx, y*2+dy, z*2+dz);
            }
        }
    }
}

struct SmokeSim : DisableCopy {
    unsigned int n;
    std::unique_ptr<CudaSurface<float4>> loc;
    std::unique_ptr<CudaTexture<float4>> vel;
    std::unique_ptr<CudaTexture<float4>> velNext;
    std::unique_ptr<CudaTexture<float>> clr;
    std::unique_ptr<CudaTexture<float>> clrNext;
    std::unique_ptr<CudaTexture<float>> tmp;
    std::unique_ptr<CudaTexture<float>> tmpNext;

    std::unique_ptr<CudaSurface<char>> bound;
    std::unique_ptr<CudaSurface<float>> div;
    std::unique_ptr<CudaSurface<float>> pre;
    //std::unique_ptr<CudaSurface<float>> preNext;
    std::vector<std::unique_ptr<CudaSurface<float>>> res;
    std::vector<std::unique_ptr<CudaSurface<float>>> res2;
    std::vector<std::unique_ptr<CudaSurface<float>>> err2;
    std::vector<unsigned int> sizes;

    explicit SmokeSim(unsigned int _n, unsigned int _n0 = 16)
    : n(_n)
    , loc(std::make_unique<CudaSurface<float4>>(uint3{n, n, n}))
    , vel(std::make_unique<CudaTexture<float4>>(uint3{n, n, n}))
    , velNext(std::make_unique<CudaTexture<float4>>(uint3{n, n, n}))
    , clr(std::make_unique<CudaTexture<float>>(uint3{n, n, n}))
    , clrNext(std::make_unique<CudaTexture<float>>(uint3{n, n, n}))
    , tmp(std::make_unique<CudaTexture<float>>(uint3{n, n, n}))
    , tmpNext(std::make_unique<CudaTexture<float>>(uint3{n, n, n}))
    , div(std::make_unique<CudaSurface<float>>(uint3{n, n, n}))
    , pre(std::make_unique<CudaSurface<float>>(uint3{n, n, n}))
    //, preNext(std::make_unique<CudaSurface<float>>(uint3{n, n, n}))
    , bound(std::make_unique<CudaSurface<char>>(uint3{n, n, n}))
    {
        fillzero_kernel<<<dim3((n + 7) / 8, (n + 7) / 8, (n + 7) / 8), dim3(8, 8, 8)>>>(pre->accessSurface(), n);

        unsigned int tn;
        for (tn = n; tn >= _n0; tn /= 2) {
            res.push_back(std::make_unique<CudaSurface<float>>(uint3{tn, tn, tn}));
            res2.push_back(std::make_unique<CudaSurface<float>>(uint3{tn/2, tn/2, tn/2}));
            err2.push_back(std::make_unique<CudaSurface<float>>(uint3{tn/2, tn/2, tn/2}));
            sizes.push_back(tn);
        }
    }

    void smooth(CudaSurface<float> *v, CudaSurface<float> *f, unsigned int lev, int times = 4) {
        unsigned int tn = sizes[lev];
        for (int step = 0; step < times; step++) {
            rbgs_kernel<0><<<dim3((tn + 7) / 8, (tn + 7) / 8, (tn + 7) / 8), dim3(8, 8, 8)>>>(v->accessSurface(), f->accessSurface(), tn);
            rbgs_kernel<1><<<dim3((tn + 7) / 8, (tn + 7) / 8, (tn + 7) / 8), dim3(8, 8, 8)>>>(v->accessSurface(), f->accessSurface(), tn);
        }
    }

    void vcycle(unsigned int lev, CudaSurface<float> *v, CudaSurface<float> *f) {
        if (lev >= sizes.size()) {
            unsigned int tn = sizes.back() / 2;
            smooth(v, f, lev);
            return;
        }
        auto *r = res[lev].get();
        auto *r2 = res2[lev].get();
        auto *e2 = err2[lev].get();
        unsigned int tn = sizes[lev];
        smooth(v, f, lev);
        residual_kernel<<<dim3((tn + 7) / 8, (tn + 7) / 8, (tn + 7) / 8), dim3(8, 8, 8)>>>(r->accessSurface(), v->accessSurface(), f->accessSurface(), tn);
        restrict_kernel<<<dim3((tn/2 + 7) / 8, (tn/2 + 7) / 8, (tn/2 + 7) / 8), dim3(8, 8, 8)>>>(r2->accessSurface(), r->accessSurface(), tn/2);
        fillzero_kernel<<<dim3((tn/2 + 7) / 8, (tn/2 + 7) / 8, (tn/2 + 7) / 8), dim3(8, 8, 8)>>>(e2->accessSurface(), tn/2);
        vcycle(lev + 1, e2, r2);
        prolongate_kernel<<<dim3((tn/2 + 7) / 8, (tn/2 + 7) / 8, (tn/2 + 7) / 8), dim3(8, 8, 8)>>>(v->accessSurface(), e2->accessSurface(), tn/2);
        smooth(v, f, lev);
    }

    void projection() {
        heatup_kernel<<<dim3((n + 7) / 8, (n + 7) / 8, (n + 7) / 8), dim3(8, 8, 8)>>>(vel->accessSurface(), tmp->accessSurface(), clr->accessSurface(), bound->accessSurface(), 0.05f, 0.018f, 0.004f, n);
        divergence_kernel<<<dim3((n + 7) / 8, (n + 7) / 8, (n + 7) / 8), dim3(8, 8, 8)>>>(vel->accessSurface(), div->accessSurface(), bound->accessSurface(), n);
        vcycle(0, pre.get(), div.get());
        subgradient_kernel<<<dim3((n + 7) / 8, (n + 7) / 8, (n + 7) / 8), dim3(8, 8, 8)>>>(pre->accessSurface(), vel->accessSurface(), bound->accessSurface(), n);
    }

    void advection() {
        advect_kernel<<<dim3((n + 7) / 8, (n + 7) / 8, (n + 7) / 8), dim3(8, 8, 8)>>>(vel->accessTexture(), loc->accessSurface(), bound->accessSurface(), n);

        resample_kernel<<<dim3((n + 7) / 8, (n + 7) / 8, (n + 7) / 8), dim3(8, 8, 8)>>>(loc->accessSurface(), vel->accessTexture(), velNext->accessSurface(), n);
        resample_kernel<<<dim3((n + 7) / 8, (n + 7) / 8, (n + 7) / 8), dim3(8, 8, 8)>>>(loc->accessSurface(), clr->accessTexture(), clrNext->accessSurface(), n);
        resample_kernel<<<dim3((n + 7) / 8, (n + 7) / 8, (n + 7) / 8), dim3(8, 8, 8)>>>(loc->accessSurface(), tmp->accessTexture(), tmpNext->accessSurface(), n);
        std::swap(vel, velNext);
        std::swap(clr, clrNext);
        std::swap(tmp, tmpNext);

        decay_kernel<<<dim3((n + 7) / 8, (n + 7) / 8, (n + 7) / 8), dim3(8, 8, 8)>>>(tmp->accessSurface(), tmpNext->accessSurface(), bound->accessSurface(), std::exp(-0.5f), std::exp(-0.0003f), n);
        decay_kernel<<<dim3((n + 7) / 8, (n + 7) / 8, (n + 7) / 8), dim3(8, 8, 8)>>>(clr->accessSurface(), clrNext->accessSurface(), bound->accessSurface(), std::exp(-0.05f), std::exp(-0.003f), n);
        std::swap(tmp, tmpNext);
        std::swap(clr, clrNext);
    }

    void step(int times = 16) {
        for (int step = 0; step < times; step++) {
            //old_projection();
            projection();
            advection();
        }
    }

    /*void old_projection(int times = 50) {
        divergence_kernel<<<dim3((n + 7) / 8, (n + 7) / 8, (n + 7) / 8), dim3(8, 8, 8)>>>(vel->accessSurface(), div->accessSurface(), bound->accessSurface(), n);

        for (int step = 0; step < times; step++) {
            jacobi_kernel<<<dim3((n + 7) / 8, (n + 7) / 8, (n + 7) / 8), dim3(8, 8, 8)>>>(div->accessSurface(), pre->accessSurface(), preNext->accessSurface(), bound->accessSurface(), n);
            std::swap(pre, preNext);
        }

        subgradient_kernel<<<dim3((n + 7) / 8, (n + 7) / 8, (n + 7) / 8), dim3(8, 8, 8)>>>(pre->accessSurface(), vel->accessSurface(), bound->accessSurface(), n);
    }*/

    float calc_loss() {
        divergence_kernel<<<dim3((n + 7) / 8, (n + 7) / 8, (n + 7) / 8), dim3(8, 8, 8)>>>(vel->accessSurface(), div->accessSurface(), bound->accessSurface(), n);
        float *sum;
        checkCudaErrors(cudaMalloc(&sum, sizeof(float)));
        sumloss_kernel<<<dim3((n + 7) / 8, (n + 7) / 8, (n + 7) / 8), dim3(8, 8, 8)>>>(div->accessSurface(), sum, n);
        float cpu;
        checkCudaErrors(cudaMemcpy(&cpu, sum, sizeof(float), cudaMemcpyDeviceToHost));
        checkCudaErrors(cudaFree(sum));
        return cpu;
    }
};

int main() {
    unsigned int n = 256;
    SmokeSim sim(n);

    {
        std::vector<char> cpu(n * n * n);
        for (int z = 0; z < n; z++) {
            for (int y = 0; y < n; y++) {
                for (int x = 0; x < n; x++) {
                    char sdf1 = std::hypot(x - (int)n / 2, y - (int)n / 2, z - (int)n / 4) < n / 12 ? -1 : 1;
                    char sdf2 = std::hypot(x - (int)n / 2, y - (int)n / 2, z - (int)n * 3 / 4) < n / 6 ? -1 : 1;
                    cpu[x + n * (y + n * z)] = sdf1;//std::min(sdf1, sdf2);
                }
            }
        }
        sim.bound->copyIn(cpu.data());
    }

    {
        std::vector<float> cpu(n * n * n);
        for (int z = 0; z < n; z++) {
            for (int y = 0; y < n; y++) {
                for (int x = 0; x < n; x++) {
                    float den = std::hypot(x - (int)n / 2, y - (int)n / 2, z - (int)n / 4) < n / 12 ? 1.f : 0.f;
                    cpu[x + n * (y + n * z)] = den;
                }
            }
        }
        sim.clr->copyIn(cpu.data());
    }

    {
        std::vector<float> cpu(n * n * n);
        for (int z = 0; z < n; z++) {
            for (int y = 0; y < n; y++) {
                for (int x = 0; x < n; x++) {
                    float tmp = std::hypot(x - (int)n / 2, y - (int)n / 2, z - (int)n / 4) < n / 12 ? 1.f : 0.f;
                    cpu[x + n * (y + n * z)] = tmp;
                }
            }
        }
        sim.tmp->copyIn(cpu.data());
    }

    {
        std::vector<float4> cpu(n * n * n);
        for (int z = 0; z < n; z++) {
            for (int y = 0; y < n; y++) {
                for (int x = 0; x < n; x++) {
                    float vel = std::hypot(x - (int)n / 2, y - (int)n / 2, z - (int)n / 4) < n / 12 ? 0.9f : 0.f;
                    cpu[x + n * (y + n * z)] = make_float4(0.f, 0.f, vel * 0.1f, 0.f);
                }
            }
        }
        sim.vel->copyIn(cpu.data());
    }

    std::vector<std::thread> tpool;
    for (int frame = 1; frame <= 200; frame++) {
        std::vector<float> cpuClr(n * n * n);
        std::vector<float> cpuTmp(n * n * n);
        sim.clr->copyOut(cpuClr.data());
        sim.tmp->copyOut(cpuTmp.data());
        tpool.push_back(std::thread([cpuClr = std::move(cpuClr), cpuTmp = std::move(cpuTmp), frame, n] {
            for (int i = 0; i < cpuTmp.size(); i++) {
                //if (cpuTmp[i] < 0) printf("wrong %d=%f\n", i, cpuTmp[i]);
            }
            VDBWriter writer;
            writer.addGrid<float, 1>("density", cpuClr.data(), n, n, n);
            writer.addGrid<float, 1>("temperature", cpuTmp.data(), n, n, n);
            writer.write("/tmp/a" + std::to_string(1000 + frame).substr(1) + ".vdb");
        }));

        printf("frame=%d, loss=%f\n", frame, sim.calc_loss());
        sim.step();
    }

    for (auto &t: tpool) t.join();
    return 0;
}
