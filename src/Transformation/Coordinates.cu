#include "Prerequisites.cuh"
#include "CubicInterp.cuh"
#include "DeviceFunctions.cuh"
#include "Helper.cuh"
#include "Transformation.cuh"


////////////////////////////
//CUDA kernel declarations//
////////////////////////////

template<bool cubicinterp> __global__ void Cart2PolarKernel(cudaTextureObject_t t_input, tfloat* d_output, int2 polardims, int2 dims);
template<bool cubicinterp> __global__ void Cart2PolarFFTKernel(cudaTextureObject_t t_input, tfloat* d_output, int2 polardims, int2 dims);

/////////////////////////////////////////////
//Equivalent of TOM's tom_cart2polar method//
/////////////////////////////////////////////

void d_Cart2Polar(tfloat* d_input, tfloat* d_output, int2 dims, T_INTERP_MODE mode, int batch)
{
	int2 polardims = GetCart2PolarSize(dims);
	tfloat* d_temp;
	if (mode == T_INTERP_CUBIC)
		cudaMalloc((void**)&d_temp, Elements2(dims) * sizeof(tfloat));

	for (int b = 0; b < batch; b++)
	{
		cudaArray* a_input;
		cudaTextureObject_t t_input;
		if (mode == T_INTERP_LINEAR)
			d_BindTextureToArray(d_input + Elements2(dims) * b, a_input, t_input, dims, cudaFilterModeLinear, false);
		else if (mode == T_INTERP_CUBIC)
		{
			cudaMemcpy(d_temp, d_input + Elements2(dims) * b, Elements2(dims) * sizeof(tfloat), cudaMemcpyDeviceToDevice);
			d_CubicBSplinePrefilter2D(d_temp, dims.x * sizeof(tfloat), dims);
			d_BindTextureToArray(d_temp, a_input, t_input, dims, cudaFilterModeLinear, false);
		}

		int TpB = min(256, NextMultipleOf(polardims.y, 32));
		dim3 grid = dim3((int)((polardims.y + TpB - 1) / TpB), polardims.x);

		if (mode == T_INTERP_LINEAR)
			Cart2PolarKernel<false> << <grid, TpB >> > (t_input, d_output + Elements2(polardims) * b, polardims, dims);
		else if (mode == T_INTERP_CUBIC)
			Cart2PolarKernel<true> << <grid, TpB >> > (t_input, d_output + Elements2(polardims) * b, polardims, dims);

		cudaDestroyTextureObject(t_input);
		cudaFreeArray(a_input);
	}

	if (mode == T_INTERP_CUBIC)
		cudaFree(d_temp);
}

int2 GetCart2PolarSize(int2 dims)
{
	int2 polardims;
	polardims.x = max(dims.x, dims.y) / 2;		//radial
	polardims.y = max(dims.x, dims.y) * 2;		//angular

	return polardims;
}

uint GetCart2PolarNonredundantSize(int2 dims)
{
	return GetCart2PolarNonredundantSize(dims, 0, dims.x / 2);
}

uint GetCart2PolarNonredundantSize(int2 dims, int maskinner, int maskouter)
{
	uint samples = 0;
	for (int r = maskinner; r < maskouter; r++)
		samples += max(1, ceil(PI2 * (tfloat)r));

	return samples;
}

float2* GetPolarNonredundantCoords(int2 dims)
{
	return GetPolarNonredundantCoords(dims, 0, dims.x / 2);
}

float2* GetPolarNonredundantCoords(int2 dims, int maskinner, int maskouter)
{
	uint size = GetCart2PolarNonredundantSize(dims, maskinner, maskouter);
	float2 center = make_float2(dims.x / 2 + 0.5f, dims.y / 2 + 0.5f);
	float2* h_coords = (float2*)malloc(size * sizeof(float2));
	float2* h_coordstemp = h_coords;

	for (int r = maskinner; r < maskouter; r++)
	{
		if (r == 0)
		{
			*h_coordstemp++ = center;
			continue;
		}
		int steps = ceil(PI2 * (float)r);
		float stepangle = PI2 / (float)steps;
		float fr = (float)r;
		for (int a = 0; a < steps; a++)
		{
			float angle = (float)a * stepangle;
			*h_coordstemp++ = make_float2(cos(angle) * fr + center.x, sin(angle) * fr + center.y);
		}
	}

	return h_coords;
}

uint GetCart2PolarFFTNonredundantSize(int2 dims)
{
	return GetCart2PolarFFTNonredundantSize(dims, 0, max(dims.x, dims.y) / 2);
}

uint GetCart2PolarFFTNonredundantSize(int2 dims, int maskinner, int maskouter)
{
	uint samples = 0;
	for (int r = maskinner; r < maskouter; r++)
		samples += r * 2;

	return samples;
}

float2* GetPolarFFTNonredundantCoords(int2 dims)
{
	return GetPolarFFTNonredundantCoords(dims, 0, dims.x / 2);
}

float2* GetPolarFFTNonredundantCoords(int2 dims, int maskinner, int maskouter)
{
	uint size = GetCart2PolarFFTNonredundantSize(dims);
	float2 center = make_float2(dims.x / 2 + 0.5f, dims.y / 2 + 0.5f);
	float2* h_coords = (float2*)malloc(size * sizeof(float2));
	float2* h_coordstemp = h_coords;

	for (int r = maskinner; r < maskouter; r++)
	{
		if (r == 0)
		{
			*h_coordstemp++ = center;
			continue;
		}
		int steps = ceil(PI * (float)r);
		float stepangle = PI / (float)steps;
		float fr = (float)r;
		for (int a = 0; a < steps; a++)
		{
			float angle = (float)a * stepangle + PIHALF;
			*h_coordstemp++ = make_float2(cos(angle) * fr + center.x, sin(angle) * fr + center.y);
		}
	}

	return h_coords;
}

void d_Cart2PolarFFT(tfloat* d_input, tfloat* d_output, int2 dims, T_INTERP_MODE mode, int batch)
{
	int2 polardims = GetCart2PolarFFTSize(dims);
	tfloat* d_temp;
	if (mode == T_INTERP_CUBIC)
		cudaMalloc((void**)&d_temp, Elements2(dims) * sizeof(tfloat));

	for (int b = 0; b < batch; b++)
	{
		cudaArray* a_input;
		cudaTextureObject_t t_input;
		if (mode == T_INTERP_LINEAR)
			d_BindTextureToArray(d_input + ElementsFFT2(dims) * b, a_input, t_input, toInt2(dims.x / 2 + 1, dims.y), cudaFilterModeLinear, false);
		else if (mode == T_INTERP_CUBIC)
		{
			cudaMemcpy(d_temp, d_input + ElementsFFT2(dims) * b, ElementsFFT2(dims) * sizeof(tfloat), cudaMemcpyDeviceToDevice);
			d_CubicBSplinePrefilter2D(d_temp, (dims.x / 2 + 1) * sizeof(tfloat), toInt2(dims.x / 2 + 1, dims.y));
			d_BindTextureToArray(d_temp, a_input, t_input, toInt2(dims.x / 2 + 1, dims.y), cudaFilterModeLinear, false);
		}

		int TpB = min(256, NextMultipleOf(polardims.y, 32));
		dim3 grid = dim3((int)((polardims.y + TpB - 1) / TpB), polardims.x);

		if (mode == T_INTERP_LINEAR)
			Cart2PolarFFTKernel<false> << <grid, TpB >> > (t_input, d_output + Elements2(polardims) * b, polardims, dims);
		else if (mode == T_INTERP_CUBIC)
			Cart2PolarFFTKernel<true> << <grid, TpB >> > (t_input, d_output + Elements2(polardims) * b, polardims, dims);

		cudaDestroyTextureObject(t_input);
		cudaFreeArray(a_input);
	}

	if (mode == T_INTERP_CUBIC)
		cudaFree(d_temp);
}

int2 GetCart2PolarFFTSize(int2 dims)
{
	int2 polardims;
	polardims.x = max(dims.x, dims.y) / 2;		//radial
	polardims.y = max(dims.x, dims.y);		//angular

	return polardims;
}


////////////////
//CUDA kernels//
////////////////

template<bool cubicinterp> __global__ void Cart2PolarKernel(cudaTextureObject_t t_input, tfloat* d_output, int2 polardims, int2 dims)
{
	int idy = blockIdx.x * blockDim.x + threadIdx.x;
	if (idy >= polardims.y)
		return;
	int idx = blockIdx.y;

	tfloat r = (tfloat)idx;
	tfloat phi = (tfloat)idy / (tfloat)polardims.y * PI2;

	tfloat val;
	if (cubicinterp)
		val = cubicTex2D(t_input, cos(phi) * r + (dims.x / 2) + (tfloat)0.5, sin(phi) * r + (dims.y / 2) + (tfloat)0.5);
	else
		val = tex2D<tfloat>(t_input, cos(phi) * r + (dims.x / 2) + (tfloat)0.5, sin(phi) * r + (dims.y / 2) + (tfloat)0.5);

	d_output[idy * polardims.x + idx] = val;
}

template<bool cubicinterp> __global__ void Cart2PolarFFTKernel(cudaTextureObject_t t_input, tfloat* d_output, int2 polardims, int2 dims)
{
	int idy = blockIdx.x * blockDim.x + threadIdx.x;
	if (idy >= polardims.y)
		return;
	int idx = blockIdx.y;

	tfloat r = (tfloat)idx;
	tfloat phi = (tfloat)(idy) / (tfloat)polardims.y * PI + PIHALF;

	tfloat val;
	if (cubicinterp)
		val = cubicTex2D(t_input, cos(phi) * r + (dims.x / 2) + (tfloat)0.5, sin(phi) * r + (dims.y / 2) + (tfloat)0.5);
	else
		val = tex2D<tfloat>(t_input, cos(phi) * r + (dims.x / 2) + (tfloat)0.5, sin(phi) * r + (dims.y / 2) + (tfloat)0.5);

	d_output[idy * polardims.x + idx] = val;
}