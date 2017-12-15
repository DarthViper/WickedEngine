//  Copyright(c) 2016, Michal Skalsky
//  All rights reserved.
//
//  Redistribution and use in source and binary forms, with or without modification,
//  are permitted provided that the following conditions are met:
//
//  1. Redistributions of source code must retain the above copyright notice,
//     this list of conditions and the following disclaimer.
//
//  2. Redistributions in binary form must reproduce the above copyright notice,
//     this list of conditions and the following disclaimer in the documentation
//     and/or other materials provided with the distribution.
//
//  3. Neither the name of the copyright holder nor the names of its contributors
//     may be used to endorse or promote products derived from this software without
//     specific prior written permission.
//
//  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY
//  EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
//  OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.IN NO EVENT
//  SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
//  SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT
//  OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
//  HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR
//  TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE,
//  EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

#ifndef _ATMOSPHERE_HF_
#define _ATMOSPHERE_HF_

RWTexture3D<float4> _SkyboxLUT;
RWTexture3D<float2> _SkyboxLUT2;

RWTexture3D<float4> _InscatteringLUT;
RWTexture3D<float4> _ExtinctionLUT;

Texture2D<float2> _ParticleDensityLUT;
SamplerState sampler_ParticleDensityLUT;
SamplerState PointClampSampler;
SamplerState LinearClampSampler;

float _AtmosphereHeight;
float _PlanetRadius;
float4 _DensityScaleHeight;
float4 _ScatteringR;
float4 _ScatteringM;
float4 _ExtinctionR;
float4 _ExtinctionM;

float4 _InscatteringLUTSize;

float4 _BottomLeftCorner;
float4 _BottomRightCorner;
float4 _TopLeftCorner;
float4 _TopRightCorner;

float4 _LightDir;
float4 _CameraPos;

float4 _IncomingLight;
float _MieG;
float _DistanceScale;

#define PI 3.14159265359

//-----------------------------------------------------------------------------------------
// ScatteringOutput
//-----------------------------------------------------------------------------------------
struct ScatteringOutput
{
	float3 rayleigh;
	float3 mie;
};

//-----------------------------------------------------------------------------------------
// RaySphereIntersection
//-----------------------------------------------------------------------------------------
float2 RaySphereIntersection(float3 rayOrigin, float3 rayDir, float3 sphereCenter, float sphereRadius)
{
	rayOrigin -= sphereCenter;
	float a = dot(rayDir, rayDir);
	float b = 2.0 * dot(rayOrigin, rayDir);
	float c = dot(rayOrigin, rayOrigin) - (sphereRadius * sphereRadius);
	float d = b * b - 4 * a * c;
	if (d < 0)
	{
		return -1;
	}
	else
	{
		d = sqrt(d);
		return float2(-b - d, -b + d) / (2 * a);
	}
}

//-----------------------------------------------------------------------------------------
// GetAtmosphereDensity
//-----------------------------------------------------------------------------------------
void GetAtmosphereDensity(float3 position, float3 planetCenter, float3 lightDir, out float2 localDensity, out float2 densityToAtmTop)
{
	float height = length(position - planetCenter) - _PlanetRadius;
	localDensity = exp(-height.xx / _DensityScaleHeight.xy);

	float cosAngle = dot(normalize(position - planetCenter), -lightDir.xyz);

	//densityToAtmTop = _ParticleDensityLUT.SampleLevel(PointClampSampler, float2(cosAngle * 0.5 + 0.5, (height / _AtmosphereHeight)), 1.0).xy;
	densityToAtmTop = _ParticleDensityLUT.SampleLevel(LinearClampSampler, float2(cosAngle * 0.5 + 0.5, (height / _AtmosphereHeight)), 0.0).xy;
}

//-----------------------------------------------------------------------------------------
// ComputeLocalInscattering
//-----------------------------------------------------------------------------------------
void ComputeLocalInscattering(float2 localDensity, float2 densityPA, float2 densityCP, out float3 localInscatterR, out float3 localInscatterM)
{
	float2 densityCPA = densityCP + densityPA;

	float3 Tr = densityCPA.x * _ExtinctionR;
	float3 Tm = densityCPA.y * _ExtinctionM;

	float3 extinction = exp(-(Tr + Tm));

	localInscatterR = localDensity.x * extinction;
	localInscatterM = localDensity.y * extinction;
}

//-----------------------------------------------------------------------------------------
// ApplyPhaseFunction
//-----------------------------------------------------------------------------------------
void ApplyPhaseFunction(inout float3 scatterR, inout float3 scatterM, float cosAngle)
{
	// r
	float phase = (3.0 / (16.0 * PI)) * (1 + (cosAngle * cosAngle));
	scatterR *= phase;

	// m
	float g = _MieG;
	float g2 = g * g;
	phase = (1.0 / (4.0 * PI)) * ((3.0 * (1.0 - g2)) / (2.0 * (2.0 + g2))) * ((1 + cosAngle * cosAngle) / (pow((1 + g2 - 2 * g*cosAngle), 3.0 / 2.0)));
	scatterM *= phase;
}

//-----------------------------------------------------------------------------------------
// IntegrateInscattering
//-----------------------------------------------------------------------------------------
ScatteringOutput IntegrateInscattering(float3 rayStart, float3 rayDir, float rayLength, float3 planetCenter, float3 lightDir)
{
	float sampleCount = 64;
	float3 step = rayDir * (rayLength / sampleCount);
	float stepSize = length(step);

	float2 densityCP = 0;
	float3 scatterR = 0;
	float3 scatterM = 0;

	float2 localDensity;
	float2 densityPA;

	float2 prevLocalDensity;
	float3 prevLocalInscatterR, prevLocalInscatterM;
	GetAtmosphereDensity(rayStart, planetCenter, lightDir, prevLocalDensity, densityPA);
	ComputeLocalInscattering(prevLocalDensity, densityPA, densityCP, prevLocalInscatterR, prevLocalInscatterM);

	// P - current integration point
	// C - camera position
	// A - top of the atmosphere
	[loop]
	for (float s = 1.0; s < sampleCount; s += 1)
	{
		float3 p = rayStart + step * s;

		GetAtmosphereDensity(p, planetCenter, lightDir, localDensity, densityPA);
		densityCP += (localDensity + prevLocalDensity) * (stepSize / 2.0);

		prevLocalDensity = localDensity;

		float3 localInscatterR, localInscatterM;
		ComputeLocalInscattering(localDensity, densityPA, densityCP, localInscatterR, localInscatterM);

		scatterR += (localInscatterR + prevLocalInscatterR) * (stepSize / 2.0);
		scatterM += (localInscatterM + prevLocalInscatterM) * (stepSize / 2.0);

		prevLocalInscatterR = localInscatterR;
		prevLocalInscatterM = localInscatterM;
	}

	ScatteringOutput output;
	output.rayleigh = scatterR;
	output.mie = scatterM;

	return output;
}

//-----------------------------------------------------------------------------------------
// PrecomputeLightScattering
//-----------------------------------------------------------------------------------------
void PrecomputeLightScattering(float3 rayStart, float3 rayDir, float rayLength, float3 planetCenter, float3 lightDir, uint3 coords, uint sampleCount)
{
	float3 step = rayDir * (rayLength / (float)(sampleCount - 1));
	float stepSize = length(step) * _DistanceScale;

	float2 densityCP = 0;
	float3 scatterR = 0;
	float3 scatterM = 0;

	float2 localDensity;
	float2 densityPA;

	float2 prevLocalDensity;
	float3 prevLocalInscatterR, prevLocalInscatterM;
	GetAtmosphereDensity(rayStart, planetCenter, lightDir, prevLocalDensity, densityPA);
	ComputeLocalInscattering(prevLocalDensity, densityPA, densityCP, prevLocalInscatterR, prevLocalInscatterM);

	_InscatteringLUT[coords] = float4(0, 0, 0, 1);
	_ExtinctionLUT[coords] = float4(1, 1, 1, 1);

	// P - current integration point
	// C - camera position
	// A - top of the atmosphere
	[loop]
	for (coords.z = 1; coords.z < sampleCount; coords.z += 1)
	{
		float3 p = rayStart + step * coords.z;

		GetAtmosphereDensity(p, planetCenter, lightDir, localDensity, densityPA);
		densityCP += (localDensity + prevLocalDensity) * (stepSize / 2.0);

		prevLocalDensity = localDensity;

		float3 localInscatterR, localInscatterM;
		ComputeLocalInscattering(localDensity, densityPA, densityCP, localInscatterR, localInscatterM);

		scatterR += (localInscatterR + prevLocalInscatterR) * (stepSize / 2.0);
		scatterM += (localInscatterM + prevLocalInscatterM) * (stepSize / 2.0);

		prevLocalInscatterR = localInscatterR;
		prevLocalInscatterM = localInscatterM;

		float3 currentScatterR = scatterR;
		float3 currentScatterM = scatterM;

		ApplyPhaseFunction(currentScatterR, currentScatterM, dot(rayDir, -lightDir.xyz));
		float3 lightInscatter = (currentScatterR * _ScatteringR + currentScatterM * _ScatteringM) * _IncomingLight.xyz;
		float3 lightExtinction = exp(-(densityCP.x * _ExtinctionR + densityCP.y * _ExtinctionM));

		_InscatteringLUT[coords] = float4(lightInscatter, 1);
		_ExtinctionLUT[coords] = float4(lightExtinction, 1);
	}
}

#endif // _ATMOSPHERE_HF_
