// This file is part of Instance Stixels:
// https://github.com/tudelft-iv/instance-stixels
//
// Originally, it was part of stixels:
// https://github.com/dhernandez0/stixels
//
// Copyright (c) 2016 Daniel Hernandez Juarez.
// Copyright (c) 2019 Thomas Hehn.
//
// Instance Stixels is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Instance Stixels is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Instance Stixels. If not, see <http://www.gnu.org/licenses/>.

#include "StixelsKernels.h"

#define MIN_STIXEL_HEIGHT 1

__inline__ __device__ float FastLog(const float v) {
    return __logf(v);
}

__inline__ __device__ float NegFastLogDiv(const float v, const float v2) {
    //return -__logf(v/v2);
    return -__logf(v) + __logf(v2);
}

__inline__ __device__ float GetPriorCost(const int vB, const int rows) {
    return NegFastLogDiv(1.0f, (float)(rows-vB));
}

__inline__ __device__ pixel_t ComputeMean(
        const int vB, const int vT, const pixel_t *d_sum, 
        const pixel_t *d_valid, const pixel_t *d_column){
#if ALLOW_INVALID_DISPARITIES
    const pixel_t valid_dif = d_valid[vT+1]-d_valid[vB];
    pixel_t mean = (valid_dif == 0) ? 0 : (d_sum[vT+1]-d_sum[vB])/valid_dif;
#else
    const pixel_t mean = (d_sum[vT+1]-d_sum[vB])/(vT+1-vB);
#endif

    return mean;
}

__inline__ __device__ pixel_t ComputeNonInstanceOffsetCost(
        const int vB, const int vT, 
        const float* instance_offsetsx, // __restricted__?
        const float* instance_offsetsy){ // __restricted__?
    float cost = 0;
    // Given a stixel includes rows {vB,..., vT} not {vB,... ,vT-1}.
    for(int r = vB; r <= vT; r++){
        // Offset of 0 is ideal.
        const float diffx = instance_offsetsx[r];
        const float diffy = instance_offsetsy[r];
        cost += (diffx * diffx) + (diffy * diffy);
    }
    return cost;
}

__inline__ __device__ pixel_t ComputeInstanceOffsetCost(
        const int vB, const int vT, 
        const float instance_stixelmeanx,
        const float instance_stixelmeany,
        const float* instance_offsetsx, // __restricted__?
        const float* instance_offsetsy, // __restricted__?
        const int column_step){
    float cost = 0;
    // stixel width is actually always column_step + 1 border.
    // mean of range(8,16) is 11.5 (column_step 8)
    const int col = blockIdx.x;
    const float meanx = column_step * col + 0.5 * (column_step-1);
    // Given a stixel includes rows {vB,..., vT} not {vB,... ,vT-1}.
    for(int r = vB; r <= vT; r++){
        // Offset which points to instance mean is ideal.
        const float diffx = meanx + instance_offsetsx[r] 
                            - instance_stixelmeanx;
        const float diffy = r + instance_offsetsy[r]
                            - instance_stixelmeany;
        cost += (diffx * diffx) + (diffy * diffy);
    }
    return cost;
}

__inline__ __device__ float GetPriorCostSkyFromObject(
        pixel_t previous_mean, const float epsilon, const float prior_cost) {
    float cost = logf(2.0f)+prior_cost;

    if(previous_mean < epsilon) {
        cost = MAX_LOGPROB;
    }
    return cost;
}

__inline__ __device__ float GetPriorCostSkyFromGround(
        const int vB, float *ground_function, const float prior_cost) {
    const int previous_vT = vB-1;

    const float prev_gf = ground_function[previous_vT];
    const float cost = (prev_gf < 1.0f) ? prior_cost : MAX_LOGPROB;

    return cost;
}

__inline__ __device__ float ComputeObjectDisparityRange(
        const float previous_mean, const float baseline,
        const float focal, const float range_objects_z) {
    float range_disp = 0;
    if(previous_mean != 0) {
        const float pmean_plus_z = 
            (baseline * focal / previous_mean) + range_objects_z;
        range_disp = previous_mean - (baseline * focal / pmean_plus_z);
    }
    return range_disp;
}

__inline__ __device__ float GetPriorCostObjectFromGround(
        const int vB, float fn, const float max_disf, 
        const float *ground_function, const float prior_cost,
        const float epsilon, const float pgrav, const float pblg) {
    float cost = -logf(0.7f) + prior_cost;

    const int previous_vT = vB-1;
    float fn_previous = ground_function[previous_vT];
    if(fn_previous < 0.0f) {
        fn_previous = 0.0f;
    }

    if(fn > (fn_previous+epsilon)) {
        // It should not be 0, fn_previous could be almost m_max_dis-1 
        // but m_epsilon should be small
        cost += NegFastLogDiv(pgrav, max_disf-fn_previous-epsilon);
    } else if(fn < (fn_previous-epsilon)) {
        // fn >= 0 then previous_mean-dif_dis > 0
        const float pmean_sub = fn_previous - epsilon;
        cost += NegFastLogDiv(pblg, pmean_sub);
    } else {
        cost += NegFastLogDiv(1.0f - pgrav - pblg, 2.0f * epsilon);
    }
    return cost;
}

__inline__ __device__ float GetPriorCostObjectFromObject(
        const int vB, const float fn, const pixel_t previous_mean, 
        const float *object_disparity_range, const int vhor, 
        const float max_disf, const float pord, const float prior_cost) {
    const int previous_vT = vB - 1;
    float cost = (previous_vT < vhor) ? -logf(0.7f) : logf(2.0f);
    cost += prior_cost;

    float dif_dis = object_disparity_range[(int) previous_mean];
    if(dif_dis < 0.0f) {
        dif_dis = 0.0f;
    }

    if(fn > (previous_mean + dif_dis)) {
        // It should not be 0, previous_mean could be almost m_max_dis-1
        // but dif_dis should be small
        cost += NegFastLogDiv(pord, max_disf - previous_mean - dif_dis);
    } else if(fn < (previous_mean - dif_dis)) {
        // fn >= 0 then previous_mean-dif_dis > 0
        const float pmean_sub = previous_mean - dif_dis;
        cost += NegFastLogDiv(1.0f - pord, pmean_sub);
    } else {
        cost = MAX_LOGPROB;
    }
    return cost;
}

__inline__ __device__ float GetPriorCostObjectFromSky(
        const float fn, const float max_disf, 
        const float prior_cost, const float epsilon) {
    float cost = MAX_LOGPROB;

    if(fn > epsilon) {
        cost = NegFastLogDiv(1.0f, max_disf - epsilon) + prior_cost;
    }

    return cost;
}

__inline__ __device__ float GetPriorCostGround(const float prior_cost) {
    return -logf(0.3f)+prior_cost;
}

__inline__ __device__ float GetPriorCostObjectFirst(
        const bool below_vhor_vT, const float rows_log, 
        const float max_dis_log) {
    const float pvt = below_vhor_vT ? logf(2.0f) : 0.0f;
    return rows_log + pvt + max_dis_log;
}

__inline__ __device__ float GetPriorCostGroundFirst(const float rows_log) {
    // Only below horizon
    return logf(2.0f) + rows_log;
}

__inline__ __device__ float GetDataCostSky(
        const pixel_t d, const float pnexists_given_sky_log, 
        const float normalization_sky, const float inv_sigma2_sky, 
        const float puniform_sky, const float nopnexists_given_sky_log) {

    float data_cost = pnexists_given_sky_log;
    if(!ALLOW_INVALID_DISPARITIES || d != INVALID_DISPARITY) {
        const float pgaussian = normalization_sky + d*d*inv_sigma2_sky;

        const float p_data = fminf(puniform_sky, pgaussian);
        data_cost = p_data+nopnexists_given_sky_log;
    }
    return data_cost;
}

__inline__ __device__ float GetDataCostGround(
        const float fn, const int v,
        const pixel_t d, const float pnexists_given_ground_log,
        const float *normalization_ground, const float *inv_sigma2_ground,
        const float puniform, const float nopnexists_given_ground_log) {

    float data_cost = pnexists_given_ground_log;
    if(!ALLOW_INVALID_DISPARITIES || d != INVALID_DISPARITY) {
        const float model_diff = (d-fn);
        const float pgaussian = normalization_ground[v]
                                + model_diff*model_diff*inv_sigma2_ground[v];

        const float p_data = fminf(puniform, pgaussian);
        data_cost = p_data + nopnexists_given_ground_log;
    }
    return data_cost;
}

__inline__ __device__ float warp_prefix_sum(
        const int i, const int fn, const pixel_t* __restrict__ d_disparity,
        const float* __restrict__ d_obj_cost_lut, 
        const StixelParameters params, float *s_data, const float add) {
    const int lane = threadIdx.x % WARP_SIZE;
    const int col = blockIdx.x;

    // Lookup the cost for current disparity value.
    int dis = 0;
    if(i+lane < params.rows) {
        dis = (int) d_disparity[col*params.rows+i+lane];
    }
    float cost = d_obj_cost_lut[fn*params.max_dis+dis];
    if(lane == 0) {
        cost += add;
    }

    // Parallel prefix sum logic.
#pragma unroll
    for (int j = 1; j < WARP_SIZE; j *= 2) {
#if (__CUDA_ARCH__ < 700)
        float n = __shfl_up(cost, j);
#else
        float n = __shfl_up_sync(0xFFFFFFFF, cost, j);
#endif

        if (lane >= j) cost += n;
    }

    // TODO: isn't the +1 terrible in terms of memory access?
    s_data[i+lane+1] = cost;

#if (__CUDA_ARCH__ < 700)
    return __shfl(cost, WARP_SIZE-1);
#else
    return __shfl_sync(0xFFFFFFFF, cost, WARP_SIZE-1);
#endif
}

__inline__ __device__ void ComputePrefixSumWarp2(
        const int fn, const pixel_t* __restrict__ d_disparity,
        const float* __restrict__ d_obj_cost_lut, 
        const StixelParameters params, float *arr,
        const int n, const int n_power2) {
    float add = 0.0f;
    const int lane = threadIdx.x % WARP_SIZE;

    if(lane == 0) {
        arr[0] = 0.0f;
    }

    // Apply warp_prefix_sum to different sections of "arr", which is a vector
    // for a single fn value.
    // First section: 0 to (warp_size-1), 2nd: warp_size to (2*warp_size-1),...
    // NOTE: The sections will write to
    // arr[1 to warp_size] and arr[warp_size+1 to 2*warp_size]
    for(int i = 0; i < n_power2; i += WARP_SIZE) {
        add = warp_prefix_sum(i, fn, d_disparity, d_obj_cost_lut, 
                              params, arr, add);
    }
}

__global__ void StixelsKernel(
        const pixel_t* __restrict__ d_disparity,
        pixel_t* __restrict__ d_segmentation,
        const StixelParameters params,
        const float* __restrict__ d_ground_function,
        const float* __restrict__ d_normalization_ground,
        const float* __restrict__ d_inv_sigma2_ground,
        const float* __restrict__ d_object_disparity_range,
        const float* __restrict__ d_object_lut,
        Section* __restrict__ d_stixels) {
    const int col = blockIdx.x;
    const int row = threadIdx.x;

    extern __shared__ int s[];
    // --- Divide shared memory into separate arrays.
    // sky_lut                  = sizeof(float)   * rows_power2
    // ground_lut               = sizeof(float)   * rows_power2
    // ground_function          = sizeof(float)   * rows_power2
    // object_disparity_range   = sizeof(float)   * max_dis
    // cost_table               = sizeof(float)   * rows_power2*3
    // index_table              = sizeof(int16_t) * rows_power2*3
    // disparity_prefixsum      = sizeof(pixel_t) * rows_power2
    // valid_disparity          = sizeof(pixel_t) * rows_power2
    // instance_offsetsx        = sizeof(pixel_t) * rows_power2
    // instance_offsetsy        = sizeof(pixel_t) * rows_power2
    // instance_meansx_prefixsum= sizeof(pixel_t) * rows_power2
    // instance_meansy_prefixsum= sizeof(pixel_t) * rows_power2
    // NULL;
    float *sky_lut = (float*)&s;
    float *ground_lut = &sky_lut[params.rows_power2];
    float *ground_function = &ground_lut[params.rows_power2];
    float *object_disparity_range = &ground_function[params.rows_power2];
    float *cost_table = &object_disparity_range[params.max_dis];
    int16_t *index_table = (int16_t*) &cost_table[params.rows_power2*3];
    pixel_t *disparity_prefixsum = 
        (pixel_t*) &index_table[params.rows_power2*3];
    pixel_t *valid_disparity = 
        (pixel_t*) &disparity_prefixsum[params.rows_power2];
    pixel_t *instance_offsetsx =
        (pixel_t*) &valid_disparity[params.rows_power2];
    pixel_t *instance_offsetsy =
        (pixel_t*) &instance_offsetsx[params.rows_power2];
    pixel_t *instance_meansx_prefixsum =
        (pixel_t*) &instance_offsetsy[params.rows_power2];
    pixel_t *instance_meansy_prefixsum =
        (pixel_t*) &instance_meansx_prefixsum[params.rows_power2];
    pixel_t *column = NULL;

    const float prior_weight = params.prior_weight;
    const float disparity_weight = params.disparity_weight;
    const float segmentation_weight = params.segmentation_weight;

    assert(params.rows % MIN_STIXEL_HEIGHT == 0);

    if(row < params.rows) {
        const pixel_t d = d_disparity[col*params.rows + row];

        cost_table[row] = MAX_LOGPROB;
        cost_table[params.rows + row] = MAX_LOGPROB;
        cost_table[2*params.rows + row] = MAX_LOGPROB;

        if(row < params.max_dis) {
            object_disparity_range[row] = d_object_disparity_range[row];
        }

#if ALLOW_INVALID_DISPARITIES
        const int va = d != INVALID_DISPARITY;
        valid_disparity[row] = (pixel_t) va;
        disparity_prefixsum[row] = ((pixel_t) va) * d;
#else
        disparity_prefixsum[row] = d;
#endif
        // --- Load instance data into shared memory.
        // Skip semantic channels indices.
        const int row_index = 
            col * params.segmentation_channels * params.rows_power2
            + params.segmentation_classes * params.rows_power2
            + row;
        // Note: input considers origin at top left and y pointing DOWN.
        // Store means used for prefix sum.
        instance_meansx_prefixsum[row] =
                params.column_step
                * (params.column_step * col + 0.5 * (params.column_step-1.0))
                + d_segmentation[row_index + params.rows_power2];
        instance_meansy_prefixsum[row] =
                params.column_step * row
                - d_segmentation[row_index/*+0*params.rows_power2*/];
        // Store offsets.
        instance_offsetsx[row] = d_segmentation[row_index + params.rows_power2]
                               / params.column_step;
        instance_offsetsy[row] = - d_segmentation[row_index]
                               / params.column_step;

        // sky_lut[row < params.vhor] will not be used, except when computing
        // prefix sum.
        sky_lut[row] = 
            (row < params.vhor) ?
            0 : //MAX_LOGPROB : 
            GetDataCostSky(d, 
                           params.pnexists_given_sky_log,
                           params.normalization_sky, 
                           params.inv_sigma2_sky,
                           params.puniform_sky, 
                           params.nopnexists_given_sky_log);

        ground_function[row] = d_ground_function[row];
        const float gf = ground_function[row];
        ground_lut[row] = 
            (row >= params.vhor) ?
            MAX_LOGPROB : 
            GetDataCostGround(gf, row, d, 
                              params.pnexists_given_ground_log,
                              d_normalization_ground, 
                              d_inv_sigma2_ground,
                              params.puniform,
                              params.nopnexists_given_ground_log);

        // Reason: Usage of "column" in the precomputation of Object LUT and
        //          need writes to luts before ComputePrefixSum
        __syncthreads();

#if ALLOW_INVALID_DISPARITIES
        ComputePrefixSum(valid_disparity, params.rows_power2);
#endif
        ComputePrefixSum(disparity_prefixsum, params.rows_power2);
        ComputePrefixSum(instance_meansx_prefixsum, params.rows_power2);
        ComputePrefixSum(instance_meansy_prefixsum, params.rows_power2);
        ComputePrefixSum(ground_lut, params.rows_power2);
        ComputePrefixSum(sky_lut, params.rows_power2);
        for(int c = 0; c < params.segmentation_classes; c++){
            // Note: We can use ComputePrefixSum after JoinColumnsSegmentation.
            ComputePrefixSum(&d_segmentation[
                                col * params.rows_power2
                                    * params.segmentation_channels
                                + c * params.rows_power2], 
                             params.rows_power2);
        }

        const float max_disf = (float) params.max_dis;

        const int vT = row;
        const int obj_data_idx = col * (params.rows_power2+1) * params.max_dis;

        // First segment: Special case vB = 0
        __syncthreads();
        if(vT % MIN_STIXEL_HEIGHT == MIN_STIXEL_HEIGHT-1){
        {
            const int vB = 0;

            // --- Compute instance term.
            pixel_t instance_stixelmeanx = (instance_meansx_prefixsum[vT+1]
                                            - instance_meansx_prefixsum[vB])
                                           / (vT+1-vB) / params.column_step;
            pixel_t instance_stixelmeany = (instance_meansy_prefixsum[vT+1]
                                            - instance_meansy_prefixsum[vB])
                                           / (vT+1-vB) / params.column_step;

            // Compute difference from instance stixel means.
            const float instance_cost = params.instance_weight *
                ComputeInstanceOffsetCost(vB, vT, 
                                          instance_stixelmeanx,
                                          instance_stixelmeany,
                                          instance_offsetsx,
                                          instance_offsetsy,
                                          params.column_step);
            // Compute difference from pixel positions.
            const float non_instance_cost = params.instance_weight *
                ComputeNonInstanceOffsetCost(vB, vT, 
                                             instance_offsetsx,
                                             instance_offsetsy);

            // Min ground semantic class
            const float cost_ground_segmentation = GetGroundSegmentationCost(
                    &d_segmentation[col * params.rows_power2
                                    * params.segmentation_channels],
                    vB, vT, params.rows_power2)
                    + non_instance_cost;
            // Min object semantic class
            const float cost_object_segmentation = GetObjectSegmentationCost(
                    &d_segmentation[col * params.rows_power2
                                    * params.segmentation_channels],
                    vB, vT, params.rows_power2, 
                    instance_cost, non_instance_cost);

            // Compute disparity data terms.
            pixel_t obj_fn = ComputeMean(vB, vT, disparity_prefixsum, valid_disparity, column);
            // Sometimes obj_fni is negative (~ -1e-5). This means that in the
            // prefix sum, there is a value which is larger that its
            // predecessor. As all entries in "sum" are positive (disparities),
            // this should not happen (I checked this.). I think this an
            // numeric issue of the "ComputePrefixSum" sum.
            // NOTE: This also means that ground_lut and sky_lut might suffer
            // from the same problem.
            if(obj_fn < 0) {
                obj_fn = 0;
            }
            const int obj_fni = (int) floorf(obj_fn);

            const float cost_ground_data = 
                ground_lut[vT+1] - ground_lut[vB];
            // NOTE: d_object_lut depends on disparity image, whereas
            // d_obj_cost_lut is precomputed and does not depend on current
            // disparity image.
            const float cost_object_data =
                d_object_lut[obj_data_idx+obj_fni*(params.rows_power2+1) +vT+1]
                -d_object_lut[obj_data_idx+obj_fni*(params.rows_power2+1) +vB];

            // Compute priors costs
            const int index_pground = vT*3 + GROUND;
            const int index_pobject = vT*3 + OBJECT;
            const bool below_vhor_vT = vT <= params.vhor;

            if(below_vhor_vT) {
                const float cost_ground_prior =
                    GetPriorCostGroundFirst(params.rows_log);
                // Ground
                const float curr_cost_ground = cost_table[index_pground];
                const float cost_ground =
                    disparity_weight * cost_ground_data 
                    + prior_weight * cost_ground_prior
                    + segmentation_weight * cost_ground_segmentation;
                if( cost_ground < curr_cost_ground ) {
                    cost_table[index_pground] = cost_ground;
                    index_table[index_pground] = GROUND;
                }
            }

            // Object
            const float cost_object_prior =
                GetPriorCostObjectFirst(below_vhor_vT, params.rows_log,
                                        params.max_dis_log);
            const float curr_cost_object = cost_table[index_pobject];
            const float cost_object = 
                disparity_weight * cost_object_data 
                + prior_weight * cost_object_prior
                + segmentation_weight * cost_object_segmentation;
            if( cost_object < curr_cost_object ) {
                cost_table[index_pobject] = cost_object;
            }
            // Since OBJECT is the fallback class, this should not remain
            // uninitialized.
            // index_table[...] < 3 will cause backtracing to finish.
            index_table[index_pobject] = OBJECT;
        }
        } // if(vT % MIN_STIXEL_HEIGHT == 0)

        // Computing cases vB > 0
        // e.g. MIN_STIXEL_HEIGHT = 8:
        // vB = 0, 8, 16, 24, 32, ...
        // vT = 7, 15, 23, 31, 43, ...
        for(int vB = MIN_STIXEL_HEIGHT; 
                vB < params.rows; 
                vB += MIN_STIXEL_HEIGHT) {
            __syncthreads();

            // Skip cases where vT (= row = threadIdx.x) is larger than vB
            // Note: insert minimum stixel size here as vB + min_size.
            if(vT >= vB && vT % MIN_STIXEL_HEIGHT == MIN_STIXEL_HEIGHT-1) {
                // --- Compute instance term.
                pixel_t instance_stixelmeanx = (instance_meansx_prefixsum[vT+1]
                                                - instance_meansx_prefixsum[vB])
                                               / (vT+1-vB) / params.column_step;
                pixel_t instance_stixelmeany = (instance_meansy_prefixsum[vT+1]
                                                - instance_meansy_prefixsum[vB])
                                               / (vT+1-vB) / params.column_step;

                // Compute difference from instance stixel means.
                const float instance_cost = params.instance_weight *
                    ComputeInstanceOffsetCost(vB, vT, 
                                              instance_stixelmeanx,
                                              instance_stixelmeany,
                                              instance_offsetsx,
                                              instance_offsetsy,
                                              params.column_step);
                // Compute difference from pixel positions.
                const float non_instance_cost = params.instance_weight *
                    ComputeNonInstanceOffsetCost(vB, vT, 
                                                 instance_offsetsx,
                                                 instance_offsetsy);

                // --- Compute semantics.
                // Min ground semantic class
                const float cost_ground_segmentation = 
                    GetGroundSegmentationCost(
                        &d_segmentation[col * params.rows_power2
                                        * params.segmentation_channels],
                        vB, vT, params.rows_power2)
                    + non_instance_cost;
                // Min object semantic class
                const float cost_object_segmentation = 
                    GetObjectSegmentationCost(
                        &d_segmentation[col * params.rows_power2
                                        * params.segmentation_channels],
                        vB, vT, params.rows_power2,
                        instance_cost, non_instance_cost);
                // Min object semantic class
                const float cost_sky_segmentation = 
                    GetSkySegmentationCost(
                        &d_segmentation[col * params.rows_power2
                                        * params.segmentation_channels],
                        vB, vT, params.rows_power2)
                    + non_instance_cost;

                // Compute disparity data term
                pixel_t obj_fn = ComputeMean(vB, vT, disparity_prefixsum, valid_disparity, column);
                // See obj_fni above.
                if(obj_fn < 0) {
                    obj_fn = 0;
                }
                const int obj_fni = (int) floorf(obj_fn);

                const float cost_object_data = 
                    d_object_lut[obj_data_idx 
                                 + obj_fni * (params.rows_power2+1)
                                 + vT+1]
                    - d_object_lut[obj_data_idx
                                   + obj_fni * (params.rows_power2+1)
                                   + vB];
                // Uniform distribution over remaining rows.
                const float prior_cost = GetPriorCost(vB, params.rows);

                // Cost for previous_vT has already been computed since
                // vT >= vB and syncthreads call above.
                const int previous_vT = vB-1;
                const bool below_vhor_vTprev = previous_vT < params.vhor;
                const int previous_object_vB = 
                    index_table[previous_vT*3 + OBJECT] / 3;
                pixel_t previous_mean = 
                    ComputeMean(previous_object_vB, previous_vT,
                                disparity_prefixsum, valid_disparity, 
                                column);
                if(previous_mean < 0) {
                    previous_mean = 0;
                }

                if(below_vhor_vTprev) { // previous_vT < parames.vhor
                    // Ground
                    const float cost_ground_data = 
                        ground_lut[vT+1] - ground_lut[vB];
                    const int index_pground = vT*3 + GROUND;

                    const float prev_cost = GetPriorCostGround(prior_cost);
                    const float cost_ground_prior1 = 
                        prior_weight * prev_cost 
                        + cost_table[previous_vT*3 + GROUND];
                    const float cost_ground_prior2 = 
                        prior_weight * prev_cost 
                        + cost_table[previous_vT*3 + OBJECT];
                    const float cost_ground_minprior = 
                        fminf(cost_ground_prior1, cost_ground_prior2);

                    const float curr_cost_ground = cost_table[index_pground];
                    const float cost_ground = 
                        disparity_weight * cost_ground_data 
                        + cost_ground_minprior
                        + segmentation_weight * cost_ground_segmentation;
                    if( cost_ground < curr_cost_ground ) {
                        cost_table[index_pground] = cost_ground;
                        int min_prev = OBJECT;
                        if(cost_ground_prior1 < cost_ground_prior2) {
                            min_prev = GROUND;
                        }
                        index_table[index_pground] = vB*3 + min_prev;
                    }
                } else { // previous_vT (=vB-1) >= params.vhor
                    // Sky
                    const float cost_sky_data = sky_lut[vT+1] - sky_lut[vB];
                    const int index_psky = vT*3 + SKY;

                    const float cost_sky_prior1 = 
                        prior_weight * 
                        GetPriorCostSkyFromGround(vB, ground_function, 
                                                  prior_cost)
                        + cost_table[previous_vT*3 + GROUND];

                    const float cost_sky_prior2 = 
                        prior_weight * 
                        GetPriorCostSkyFromObject(previous_mean,
                                                  params.epsilon, prior_cost)
                        + cost_table[previous_vT*3 + OBJECT];
                    const float cost_sky_minprior =
                        fminf(cost_sky_prior1, cost_sky_prior2);

                    const float curr_cost_sky = cost_table[index_psky];
                    const float cost_sky = 
                        disparity_weight * cost_sky_data 
                        + cost_sky_minprior
                        + segmentation_weight * cost_sky_segmentation;
                    if( cost_sky < curr_cost_sky ) {
                        cost_table[index_psky] = cost_sky;
                        int min_prev = OBJECT;
                        if(cost_sky_prior1 < cost_sky_prior2) {
                            min_prev = GROUND;
                        }
                        index_table[index_psky] = vB*3 + min_prev;
                    }
                }

                // Object
                const int index_pobject = vT*3+OBJECT;

                const float cost_object_prior1 = 
                    prior_weight * 
                    GetPriorCostObjectFromGround(vB, obj_fn, max_disf, 
                                                 ground_function, prior_cost,
                                                 params.epsilon, 
                                                 params.pgrav, params.pblg)
                    + cost_table[previous_vT*3+GROUND];

                const float cost_object_prior2 = 
                    prior_weight * 
                    GetPriorCostObjectFromObject(vB, obj_fn, previous_mean,
                                                 object_disparity_range, 
                                                 params.vhor, max_disf, 
                                                 params.pord, prior_cost) 
                    + cost_table[previous_vT*3 + OBJECT];
                const float cost_object_prior3 = 
                    prior_weight * 
                    GetPriorCostObjectFromSky(obj_fn, max_disf, prior_cost,
                                              params.epsilon)
                    + cost_table[previous_vT*3 + SKY];
                const float cost_object_minprior = 
                    fminf( fminf(cost_object_prior1, cost_object_prior2),
                           cost_object_prior3);

                const float curr_cost_object = cost_table[index_pobject];
                const float cost_object = 
                    disparity_weight * cost_object_data 
                    + cost_object_minprior
                    + segmentation_weight * cost_object_segmentation;

                if( cost_object < curr_cost_object ) {
                    cost_table[index_pobject] = cost_object;
                    int min_prev = OBJECT;
                    if(cost_object_prior1 < cost_object_prior2) {
                        min_prev = GROUND;
                    }
                    if(cost_object_prior3 < 
                            fminf(cost_object_prior1, cost_object_prior2)) {
                        min_prev = SKY;
                    }
                    index_table[index_pobject] = vB*3 + min_prev;
                }
            } // if(vT >= vB && vT % MIN_STIXEL_HEIGHT == 0) {
        }

        __syncthreads();

        // Backtracing
        if(row == 0) {
            int vT = params.rows-1;
            const float last_ground = cost_table[vT*3 + GROUND];
            const float last_object = cost_table[vT*3 + OBJECT];
            const float last_sky = cost_table[vT*3 + SKY];

            // OBJECT is the fallback geometric class. That means that in case all
            // geometric class have the same cost (most probably == MAX_LOGPROB),
            // the stixel will cover the entire column and have geometric class
            // OBJECT.
            int type = OBJECT;

            if(last_ground < last_object) {
                type = GROUND;
            }
            if(last_sky < fminf(last_ground, last_object)) {
                type = SKY;
            }
            int min_idx = vT*3 + type;

            int prev_vT;
            int i = 0;
            do {
                prev_vT = (index_table[min_idx] / 3) - 1;
                Section sec;
                sec.vT = vT;
                sec.type = type;
                sec.vB = prev_vT + 1;
                sec.disparity = 
                    (float) ComputeMean(sec.vB, sec.vT, disparity_prefixsum, valid_disparity, column);
                if(sec.type == GROUND){
                    sec.semantic_class = 
                        GetGroundSegmentationClass(
                            &d_segmentation[col
                                            * params.rows_power2
                                            * params.segmentation_channels],
                            sec.vB, sec.vT, params.rows_power2);
                }
                // OBJECTs with disparity < 1.0 are also considered SKY. This
                // is also accounted for in subsequent processing steps.
                else if(sec.type == SKY || sec.disparity < 1.0){
                    sec.semantic_class = 
                        GetSkySegmentationClass(
                            &d_segmentation[col
                                            * params.rows_power2
                                            * params.segmentation_channels],
                            sec.vB, sec.vT, params.rows_power2);
                }
                else{ // OBJECT
                    // --- Compute instance term.
                    pixel_t instance_stixelmeanx = (instance_meansx_prefixsum[sec.vT+1]
                                                    - instance_meansx_prefixsum[sec.vB])
                                                   / (sec.vT+1-sec.vB) / params.column_step;
                    pixel_t instance_stixelmeany = (instance_meansy_prefixsum[sec.vT+1]
                                                    - instance_meansy_prefixsum[sec.vB])
                                                   / (sec.vT+1-sec.vB) / params.column_step;

                    // Compute difference from instance stixel means.
                    const float instance_cost = params.instance_weight *
                        ComputeInstanceOffsetCost(sec.vB, sec.vT, 
                                                  instance_stixelmeanx,
                                                  instance_stixelmeany,
                                                  instance_offsetsx,
                                                  instance_offsetsy,
                                                  params.column_step);
                    // Compute difference from pixel positions.
                    const float non_instance_cost = params.instance_weight *
                        ComputeNonInstanceOffsetCost(sec.vB, sec.vT, 
                                                     instance_offsetsx,
                                                     instance_offsetsy);

                    sec.semantic_class = 
                        GetObjectSegmentationClass(
                            &d_segmentation[col
                                            * params.rows_power2
                                            * params.segmentation_channels],
                            sec.vB, sec.vT, params.rows_power2,
                            instance_cost, non_instance_cost);
                }
                sec.cost = fminf(cost_table[sec.vT*3+type], 1e4);
                sec.instance_meanx = (instance_meansx_prefixsum[sec.vT+1]
                                       - instance_meansx_prefixsum[sec.vB])
                                     / (sec.vT+1-sec.vB) / params.column_step;
                sec.instance_meany = (instance_meansy_prefixsum[sec.vT+1]
                                       - instance_meansy_prefixsum[sec.vB])
                                     / (sec.vT+1-sec.vB) / params.column_step;

                d_stixels[col*params.max_sections + i] = sec;

                type = index_table[min_idx] % 3;
                vT = prev_vT;
                min_idx = prev_vT*3 + type;
                i++;
                assert(i < params.max_sections);
            } while(prev_vT != -1);
            Section sec;
            sec.type = -1;
            d_stixels[col*params.max_sections+i] = sec;
        }
    }
}

__global__ void ComputeObjectLUT(
        const pixel_t* __restrict__ d_disparity,
        const float* __restrict__ d_obj_cost_lut,
        float* __restrict__ d_object_lut,
        const StixelParameters params, 
        const int n_power2) {
    const int col = blockIdx.x;
    const int warp_id = threadIdx.x / WARP_SIZE;

    const int blck_step = blockDim.x / WARP_SIZE;
    // Compute prefix sum of costs for different mean disparity values fn.
    // Each warp computes the prefix sum for a couple of fn values (for loop).
    for(int fn = warp_id; fn < params.max_dis; fn += blck_step) {
        ComputePrefixSumWarp2(
                fn, d_disparity, d_obj_cost_lut, params,
                &d_object_lut[col * (params.rows_power2+1) * params.max_dis
                              + fn * (params.rows_power2+1)],
                params.rows, n_power2);
    }
}

__global__ void JoinColumns(
        pixel_t* __restrict__ d_disparity, pixel_t* __restrict__ d_out, 
        const int step_size, const bool median,
        const int width_margin, const int rows,
        const int cols, const int real_cols) {
    const int idx = blockIdx.x*blockDim.x+threadIdx.x;
    const int row = idx / real_cols;
    const int col = idx % real_cols;

    if(idx < real_cols*rows) {
        pixel_t mean = 0.0f;
    // NOTE: 
    // 1. Computing the mean twice (specifically diving by no. stixels), here
    // and in ComputeMean is a slight deviation from the original stixel model.
    // 2. At the moment, we only consider invalid disparities in case
    // the entire row in a column is invalid.
#if ALLOW_INVALID_DISPARITIES
        int invalid = 0;
        for(int i = 0; i < step_size; i++) {
            const pixel_t d =
                d_disparity[row*cols + col*step_size + i + width_margin];
            if(d != INVALID_DISPARITY){
                mean += d;
            }
            else{
                invalid++;
            }
        }
        if(invalid != step_size){
            d_out[col*rows + rows - row-1] = mean / (step_size - invalid);
        }
        else{
            d_out[col*rows + rows - row-1] = INVALID_DISPARITY;
        }
#else
        for(int i = 0; i < step_size; i++) {
            mean += d_disparity[row*cols + col*step_size + i + width_margin];
        }
        d_out[col*rows + rows - row-1] = mean / step_size;
#endif
    }
}

__global__ void JoinColumnsSegmentation(
        pixel_t* __restrict__ d_segmentation, 
        pixel_t* __restrict__ d_out, const int step_size,
        const int width_margin, const int rows, const int cols,
        const int channels, const int real_cols, const int rows_power2) {
    const int idx = blockIdx.x*blockDim.x + threadIdx.x;
    const int row = idx / real_cols;
    const int col = idx % real_cols;

    if(idx < real_cols*rows) {
        for(int channel = 0; channel < channels; channel++){
            pixel_t sum = 0.0f;
            for(int i = 0; i < step_size; i++) {
                // Accessing a 3D array (rows, cols, channels)
                sum += d_segmentation[row * cols * channels 
                                      + col * step_size * channels
                                      + i*channels 
                                      + channel + width_margin];
            }
            // We have to invert the rows, since for images row 0, col 0 is the
            // upper left corner. Instead we want it to be the lower left
            // corner and column-major.
            // (cols, channels, rows)
            d_out[col * channels * rows_power2 
                  + channel * rows_power2 
                  + (rows-1) - row] = 
              sum;
        }
    }
}
