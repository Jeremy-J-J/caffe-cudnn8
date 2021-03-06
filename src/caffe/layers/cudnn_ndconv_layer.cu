#ifdef USE_CUDNN
#include <vector>

#include "caffe/filler.hpp"
#include "caffe/layer.hpp"
#include "caffe/layers/cudnn_ndconv_layer.hpp"
#include "caffe/util/im2col.hpp"
#include "caffe/util/math_functions.hpp"

namespace caffe {

__global__ void sync_ndconv_groups() { }

template <typename Dtype>
void CudnnNdConvolutionLayer<Dtype>::Forward_gpu(
  const vector<Blob<Dtype>*>& bottom, const vector<Blob<Dtype>*>& top) {
  
  #if CUDNN_VERSION_MIN(8, 0, 0)  //0
  int RetCnt;
  bool found_conv_algorithm;
  size_t free_memory, total_memory;
  cudnnConvolutionFwdAlgoPerf_t     fwd_algo_pref_[4];
  //cudnnConvolutionBwdDataAlgoPerf_t bwd_data_algo_pref_[4];

  //get memory sizes
  cudaMemGetInfo(&free_memory, &total_memory);
  #endif

  for (int i = 0; i < bottom.size(); ++i) {
    const Dtype* bottom_data = bottom[i]->gpu_data();
    Dtype* top_data = top[i]->mutable_gpu_data();
    const Dtype* weight = this->blobs_[0]->gpu_data();

    size_t workspace_limit_bytes = this->channels_*sizeof(int);
    for (int j = 0; j < this->kernel_shape_.size(); ++j) {
      workspace_limit_bytes *= kernel_shape_[j];
    }
    ++workspace_limit_bytes;

    // Forward through cuDNN in parallel over groups.
    for (int g = 0; g < this->group_; g++) {
      cudnnConvolutionFwdAlgo_t algo;
      #if  CUDNN_VERSION_MIN(8, 0, 0)  // 0
      // choose forward algorithm for filter
      // in forward filter the CUDNN_CONVOLUTION_FWD_ALGO_WINOGRAD_NONFUSED is not implemented in cuDNN 8
      CUDNN_CHECK(cudnnGetConvolutionForwardAlgorithm_v7(handle_[0],
        bottom_descs_[i],
        filter_desc_,
        conv_descs_[i],
        top_descs_[i],
        4,
        &RetCnt,
        fwd_algo_pref_));

      found_conv_algorithm = false;
      for(int n=0;n<RetCnt;n++){
        if (fwd_algo_pref_[n].status == CUDNN_STATUS_SUCCESS &&
            fwd_algo_pref_[n].algo != CUDNN_CONVOLUTION_FWD_ALGO_WINOGRAD_NONFUSED &&
            fwd_algo_pref_[n].memory < free_memory){
          found_conv_algorithm = true;
          //fwd_algo_[i]                   = fwd_algo_pref_[n].algo;
          //workspace_fwd_sizes_[i]        = fwd_algo_pref_[n].memory;
          algo = fwd_algo_pref_[n].algo;
          break;
        }
      }
      if(!found_conv_algorithm) 
         LOG(ERROR) << "[Forward_gpu()]cuDNN did not return a suitable algorithm for convolution.";
      #else
      // pick the convolution algorithm
      // TODO(shelhamer) this should be done during reshape
      // TODO(shelhamer) the choice of automatic or manual algorithm picking
      // should be exposed in proto
      CUDNN_CHECK(cudnnGetConvolutionForwardAlgorithm(handle_[g],
                  bottom_descs_[i],
                  filter_desc_,
                  conv_descs_[i],
                  top_descs_[i],
                  CUDNN_CONVOLUTION_FWD_SPECIFY_WORKSPACE_LIMIT,
                  workspace_limit_bytes,  // memoryLimitInBytes,
                  &algo));
      #endif
      // get minimum size of the workspace needed for the desired algorithm
      size_t workspaceSizeInBytes_temp = 0;

      CUDNN_CHECK(cudnnGetConvolutionForwardWorkspaceSize(handle_[g],
                  bottom_descs_[i],
                  filter_desc_,
                  conv_descs_[i],
                  top_descs_[i],
                  algo,
                  &workspaceSizeInBytes_temp));

      if (workspaceSizeInBytes_temp > workspaceSizeInBytes) {
        workspaceSizeInBytes = workspaceSizeInBytes_temp;
        // free the existing workspace and allocate a new (larger) one
        cudaFree(this->workspace_data_);
        cudaError_t err = cudaMalloc(&(this->workspace_data_),
                          workspaceSizeInBytes);
        if (err != cudaSuccess) {
          // force zero memory path
          algo = CUDNN_CONVOLUTION_FWD_ALGO_IMPLICIT_GEMM;
          workspace_data_ = NULL;
          workspaceSizeInBytes = 0;
        }
      }

      // Filters.
      CUDNN_CHECK(cudnnConvolutionForward(handle_[g],
                  cudnn::dataType<Dtype>::one,
                  bottom_descs_[i], bottom_data + bottom_offset_ * g,
                  filter_desc_, weight + weight_offset_ * g,
                  conv_descs_[i],
                  algo, workspace_data_, workspaceSizeInBytes,
                  cudnn::dataType<Dtype>::zero,
                  top_descs_[i], top_data + top_offset_ * g));

      // Bias.
      if (this->bias_term_) {
        const Dtype* bias_data = this->blobs_[1]->gpu_data();
#if CUDNN_VERSION_MIN(5, 0, 0)
        CUDNN_CHECK(cudnnAddTensor(handle_[g],
                    cudnn::dataType<Dtype>::one,
                    bias_desc_, bias_data + bias_offset_ * g,
                    cudnn::dataType<Dtype>::one,
                    top_descs_[i], top_data + top_offset_ * g));
#else
        CUDNN_CHECK(cudnnAddTensor_v3(handle_[g],
                    cudnn::dataType<Dtype>::one,
                    bias_desc_, bias_data + bias_offset_ * g,
                    cudnn::dataType<Dtype>::one,
                    top_descs_[i], top_data + top_offset_ * g));
#endif
      }
    }

    // Synchronize the work across groups, each of which went into its own
    // stream, by launching an empty kernel into the default (null) stream.
    // NOLINT_NEXT_LINE(whitespace/operators)
    sync_ndconv_groups<<<1, 1>>>();
  }
}

template <typename Dtype>
void CudnnNdConvolutionLayer<Dtype>::Backward_gpu(
  const vector<Blob<Dtype>*>& top,
  const vector<bool>& propagate_down,
  const vector<Blob<Dtype>*>& bottom) {
  const Dtype* weight = NULL;
  Dtype* weight_diff = NULL;
  if (this->param_propagate_down_[0]) {
    weight = this->blobs_[0]->gpu_data();
    weight_diff = this->blobs_[0]->mutable_gpu_diff();
  }
  Dtype* bias_diff = NULL;
  if (this->bias_term_ && this->param_propagate_down_[1]) {
    bias_diff = this->blobs_[1]->mutable_gpu_diff();
  }
  for (int i = 0; i < top.size(); ++i) {
    const Dtype* top_diff = top[i]->gpu_diff();
    // Backward through cuDNN in parallel over groups and gradients.
    for (int g = 0; g < this->group_; g++) {
      // Gradient w.r.t. bias.
      if (this->bias_term_ && this->param_propagate_down_[1]) {
        CUDNN_CHECK(cudnnConvolutionBackwardBias(handle_[0*this->group_ + g],
                    cudnn::dataType<Dtype>::one,
                    top_descs_[i],  top_diff + top_offset_ * g,
                    cudnn::dataType<Dtype>::one,
                    bias_desc_, bias_diff + bias_offset_ * g));
      }

      // Gradient w.r.t. weights.
      if (this->param_propagate_down_[0]) {
        const Dtype* bottom_data = bottom[i]->gpu_data();
#if CUDNN_VERSION_MIN(5, 0, 0)
        CUDNN_CHECK(cudnnConvolutionBackwardFilter(handle_[1*this->group_ +
                    g],
                    cudnn::dataType<Dtype>::one,
                    bottom_descs_[i], bottom_data + bottom_offset_ * g,
                    top_descs_[i],    top_diff + top_offset_ * g,
                    conv_descs_[i],
                    bwd_filter_algo_[i], workspace_[1*this->group_ + g],
                    workspace_bwd_filter_sizes_[i],
                    cudnn::dataType<Dtype>::one,
                    filter_desc_, weight_diff + weight_offset_ * g));
#elif CUDNN_VERSION_MIN(4, 0, 0)
        CUDNN_CHECK(cudnnConvolutionBackwardFilter_v2(handle_[1*this->group_ +
                    g],
                    cudnn::dataType<Dtype>::one,
                    bottom_descs_[i], bottom_data + bottom_offset_ * g,
                    top_descs_[i],    top_diff + top_offset_ * g,
                    conv_descs_[i],
                    cudnn::dataType<Dtype>::one,
                    filter_desc_, weight_diff + weight_offset_ * g));
#else
        CUDNN_CHECK(cudnnConvolutionBackwardFilter(handle_[1*this->group_ +
                    g],
                    cudnn::dataType<Dtype>::one,
                    bottom_descs_[i], bottom_data + bottom_offset_ * g,
                    top_descs_[i],    top_diff + top_offset_ * g,
                    conv_descs_[i],
                    cudnn::dataType<Dtype>::one,
                    filter_desc_, weight_diff + weight_offset_ * g));
#endif
      }

      // Gradient w.r.t. bottom data.
      if (propagate_down[i]) {
        if (weight == NULL) {
          weight = this->blobs_[0]->gpu_data();
        }
        Dtype* bottom_diff = bottom[i]->mutable_gpu_diff();
#if CUDNN_VERSION_MIN(5, 0, 0)
        CUDNN_CHECK(cudnnConvolutionBackwardData(handle_[2*this->group_ + g],
                    cudnn::dataType<Dtype>::one,
                    filter_desc_, weight + weight_offset_ * g,
                    top_descs_[i], top_diff + top_offset_ * g,
                    conv_descs_[i],
                    bwd_data_algo_[i], workspace_[1*this->group_ + g],
                    workspace_bwd_data_sizes_[i],
                    cudnn::dataType<Dtype>::zero,
                    bottom_descs_[i], bottom_diff + bottom_offset_ * g));
#elif CUDNN_VERSION_MIN(4, 0, 0)
        CUDNN_CHECK(cudnnConvolutionBackwardData_v2(handle_[2*this->group_ + g],
                    cudnn::dataType<Dtype>::one,
                    filter_desc_, weight + weight_offset_ * g,
                    top_descs_[i], top_diff + top_offset_ * g,
                    conv_descs_[i],
                    cudnn::dataType<Dtype>::zero,
                    bottom_descs_[i], bottom_diff + bottom_offset_ * g));
#else
        CUDNN_CHECK(cudnnConvolutionBackwardData(handle_[2*this->group_ + g],
                    cudnn::dataType<Dtype>::one,
                    filter_desc_, weight + weight_offset_ * g,
                    top_descs_[i], top_diff + top_offset_ * g,
                    conv_descs_[i],
                    cudnn::dataType<Dtype>::zero,
                    bottom_descs_[i], bottom_diff + bottom_offset_ * g));
#endif
      }
    }

    // Synchronize the work across groups, each of which went into its own
    // stream, by launching an empty kernel into the default (null) stream.
    // NOLINT_NEXT_LINE(whitespace/operators)
    sync_ndconv_groups<<<1, 1>>>();
  }
}

INSTANTIATE_LAYER_GPU_FUNCS(CudnnNdConvolutionLayer);

}  // namespace caffe
#endif
