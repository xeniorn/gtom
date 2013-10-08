#include "../Prerequisites.cuh"
#include "../Functions.cuh"
#include "../CubicSplines/internal/cubicTexKernels.cu"


////////////////////////////
//CUDA kernel declarations//
////////////////////////////

__global__ void Cart2PolarLinearKernel(tfloat* d_output, int2 polardims, tfloat radius);
__global__ void Cart2PolarCubicKernel(tfloat* d_output, int2 polardims, tfloat radius);


///////////
//Globals//
///////////

texture<tfloat, 2, cudaReadModeElementType> texInput2d;

/////////////////////////////////////////////
//Equivalent of TOM's tom_cart2polar method//
/////////////////////////////////////////////

void d_Cart2Polar(tfloat* d_input, tfloat* d_output, int2 dims, T_INTERP_MODE interpolation, int batch)
{
	int2 polardims = GetCart2PolarSize(dims);

	texInput2d.normalized = false;
	texInput2d.filterMode = cudaFilterModeLinear;

	size_t elements = dims.x * dims.y;
	size_t polarelements = polardims.x * polardims.y;

	tfloat* d_pitched = NULL;
	int pitchedwidth = dims.x * sizeof(tfloat);
	if((dims.x * sizeof(tfloat)) % 32 != 0)
		d_pitched = (tfloat*)CudaMallocAligned2D(dims.x * sizeof(tfloat), dims.y, &pitchedwidth);

	for (int b = 0; b < batch; b++)
	{
		cudaChannelFormatDesc desc = cudaCreateChannelDesc<tfloat>();
		tfloat* d_offsetinput = d_input + elements * b;
		if(d_pitched != NULL)
		{
			for (int y = 0; y < dims.y; y++)
				cudaMemcpy((char*)d_pitched + y * pitchedwidth, 
							d_offsetinput + y * dims.x, 
							dims.x * sizeof(tfloat), 
							cudaMemcpyDeviceToDevice);
			d_offsetinput = d_pitched;
		}
			
		if(interpolation == T_INTERP_CUBIC)
			d_CubicBSplinePrefilter2D(d_offsetinput, pitchedwidth, dims);

		cudaBindTexture2D(NULL, 
							texInput2d, 
							d_offsetinput, 
							desc, 
							dims.x, 
							dims.y, 
							pitchedwidth);

		size_t TpB = min(256, polardims.y);
		dim3 grid = dim3((int)((polardims.y + TpB - 1) / TpB), polardims.x);

		if(interpolation == T_INTERP_LINEAR)
			Cart2PolarLinearKernel <<<grid, (uint)TpB>>> (d_output + polarelements * b, polardims, (tfloat)max(dims.x, dims.y) / (tfloat)2);
		else if(interpolation == T_INTERP_CUBIC)
			Cart2PolarCubicKernel <<<grid, (uint)TpB>>> (d_output + polarelements * b, polardims, (tfloat)max(dims.x, dims.y) / (tfloat)2);

		cudaUnbindTexture(texInput2d);
	}

	if(d_pitched != NULL)
		cudaFree(d_pitched);
}

int2 GetCart2PolarSize(int2 dims)
{
	int2 polardims;
	polardims.x = max(dims.x, dims.y) / 2;		//radial
	polardims.y = max(dims.x, dims.y) * 2;		//angular

	return polardims;
}


////////////////
//CUDA kernels//
////////////////

__global__ void Cart2PolarLinearKernel(tfloat* d_output, int2 polardims, tfloat radius)
{
	int idy = blockIdx.x * blockDim.x + threadIdx.x;
	if(idy >= polardims.y)
		return;
	int idx = blockIdx.y;

	tfloat r = (tfloat)idx;
	tfloat phi = (tfloat)(idy) * PI2 / (tfloat)polardims.y;

	d_output[idy * polardims.x + idx] = tex2D(texInput2d, 
											  cos(phi) * r + radius + (tfloat)0.5, 
											  sin(phi) * r + radius + (tfloat)0.5);
}

__global__ void Cart2PolarCubicKernel(tfloat* d_output, int2 polardims, tfloat radius)
{
	int idy = blockIdx.x * blockDim.x + threadIdx.x;
	if(idy >= polardims.y)
		return;
	int idx = blockIdx.y;

	tfloat r = (tfloat)idx;
	tfloat phi = (tfloat)(idy) * PI2 / (tfloat)polardims.y;

	d_output[idy * polardims.x + idx] = cubicTex2D(texInput2d, 
												  cos(phi) * r + radius + (tfloat)0.5, 
												  sin(phi) * r + radius + (tfloat)0.5);
}