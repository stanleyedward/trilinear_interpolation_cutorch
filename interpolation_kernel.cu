#include <torch/extension.h>

template <typename scalar_t> // scalar_t is a placeholder dtype so we dont have to explicitly define the dtype
__global__ void trilinear_forward_kernel(
            const torch::PackedTensorAccessor<scalar_t, 3, torch::RestrictPtrTraits, size_t> features,
            const torch::PackedTensorAccessor<scalar_t, 2, torch::RestrictPtrTraits, size_t> points,
            torch::PackedTensorAccessor<scalar_t, 2, torch::RestrictPtrTraits, size_t> output
){
    const int n = blockDim.x * blockIdx.x + threadIdx.x;
    const int f = blockDim.y * blockIdx.y + threadIdx.y;

    if (n < features.size(0) && f < features.size(2)){
        //since the range for points is [-1, 1] we div by 2 to normalize
        const scalar_t u = (points[n][0] + 1)/2;
        const scalar_t v = (points[n][1] + 1)/2;
        const scalar_t w = (points[n][2] + 1)/2;    

        //interpolation coef
        const scalar_t a = (1-v)*(1-w);
        const scalar_t b = (1-v)*w;
        const scalar_t c = v*(1-w);
        const scalar_t d = 1-a-b-c;

        output[n][f] = (1-u)*(a*features[n][0][f] +
                        b*features[n][1][f] +
                        c*features[n][2][f] + 
                        d*features[n][3][f]) +
                        u*(a*features[n][4][f]+
                        b*features[n][5][f]+
                        c*features[n][6][f]+
                        d*features[n][7][f]);
    }
}


torch::Tensor trilinear_forward_cu(
    const torch::Tensor features,
    const torch::Tensor points        
){  
    const int N = features.size(0), F = features.size(2); //  num of cubes and dimension of features in each vertex

    // feat_interp_output = torch.zeros(N, F, dtype=torch.float32, device='cuda:0')
    // torch::zeros({N,F}, torch::dtype(torch::kInt32).device(features.device())); // change tensors dtype and device
    torch::Tensor featInterpOutput = torch::empty({N, F}, features.options()); // options sets dtype and device same as features
    const dim3 numThreadsPerBlock(16, 16, 1); //256 threads in each dim
    const dim3 numBlocks((N + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x, (F + numThreadsPerBlock.y - 1) / numThreadsPerBlock.y);

    // instantiate kernel
    AT_DISPATCH_FLOATING_TYPES(features.type(), "trilinear_forward_cu()", 
    ([&] {
        trilinear_forward_kernel<scalar_t><<<numBlocks, numThreadsPerBlock>>>(
            // packed accessor is type conversion for tensors so cuda can manipulate them (not needed by primitive cpp dtypes)
            // restrictPtrTraits: to prevent memory overlay of tensors
            // size_t:  how many steps to take btw each element 
            features.packed_accessor<scalar_t, 3, torch::RestrictPtrTraits, size_t>(),         
            points.packed_accessor<scalar_t, 2, torch::RestrictPtrTraits, size_t>(),
            featInterpOutput.packed_accessor<scalar_t, 2, torch::RestrictPtrTraits, size_t>()
        );
    })  
    );

    return featInterpOutput;
}

template <typename scalar_t>
__global__ void trilinear_backward_kernel(
            const torch::PackedTensorAccessor<scalar_t, 3, torch::RestrictPtrTraits, size_t> features,         
            const torch::PackedTensorAccessor<scalar_t, 2, torch::RestrictPtrTraits, size_t> points,
            const torch::PackedTensorAccessor<scalar_t, 2, torch::RestrictPtrTraits, size_t> dL_dfeatInterpOutput,
            torch::PackedTensorAccessor<scalar_t, 3, torch::RestrictPtrTraits, size_t> dL_dFeatures
){

    const int n = blockDim.x * blockIdx.x + threadIdx.x;
    const int f = blockDim.y * blockIdx.y + threadIdx.y;

    if (n < features.size(0) && f < features.size(2)){
        //since the range for points is [-1, 1] we div by 2 to normalize
        const scalar_t u = (points[n][0] + 1)/2;
        const scalar_t v = (points[n][1] + 1)/2;
        const scalar_t w = (points[n][2] + 1)/2;    

        //interpolation coef
        const scalar_t a = (1-v)*(1-w);
        const scalar_t b = (1-v)*w;
        const scalar_t c = v*(1-w);
        const scalar_t d = 1-a-b-c;

        dL_dFeatures[n][0][f] = (1-u) * a * dL_dfeatInterpOutput[n][f];
        dL_dFeatures[n][1][f] = (1-u) * b * dL_dfeatInterpOutput[n][f];
        dL_dFeatures[n][2][f] = (1-u) * c * dL_dfeatInterpOutput[n][f];
        dL_dFeatures[n][3][f] = (1-u) * d * dL_dfeatInterpOutput[n][f];
        dL_dFeatures[n][4][f] = u * a * dL_dfeatInterpOutput[n][f];
        dL_dFeatures[n][5][f] = u * b * dL_dfeatInterpOutput[n][f];
        dL_dFeatures[n][6][f] = u * c * dL_dfeatInterpOutput[n][f];
        dL_dFeatures[n][7][f] = u * d * dL_dfeatInterpOutput[n][f];
    }
}


torch::Tensor trilinear_backward_cu(
    const torch::Tensor dL_dfeatInterpOutput,
    const torch::Tensor features,
    const torch::Tensor points        
){  
    const int N = features.size(0), F = features.size(2); //  num of cubes and dimension of features in each vertex

    torch::Tensor dL_dFeatures = torch::empty({N, 8, F}, features.options()); 
    const dim3 numThreadsPerBlock(16, 16, 1); 
    const dim3 numBlocks((N + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x, (F + numThreadsPerBlock.y - 1) / numThreadsPerBlock.y);

    // instantiate kernel
    AT_DISPATCH_FLOATING_TYPES(features.type(), "trilinear_backward_cu()", 
    ([&] {
        trilinear_backward_kernel<scalar_t><<<numBlocks, numThreadsPerBlock>>>(
            // packed accessor is type conversion for tensors so cuda can manipulate them (not needed by primitive cpp dtypes)
            // restrictPtrTraits: to prevent memory overlay of tensors
            // size_t:  how many steps to take btw each element 
            features.packed_accessor<scalar_t, 3, torch::RestrictPtrTraits, size_t>(),         
            points.packed_accessor<scalar_t, 2, torch::RestrictPtrTraits, size_t>(),
            dL_dfeatInterpOutput.packed_accessor<scalar_t, 2, torch::RestrictPtrTraits, size_t>(),
            dL_dFeatures.packed_accessor<scalar_t, 3, torch::RestrictPtrTraits, size_t>()
        );
    })  
    );

    return dL_dFeatures;
}
