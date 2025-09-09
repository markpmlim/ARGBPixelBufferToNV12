//
//  Shaders.metal
//  PixelBufferToNV12
//
//

#include <metal_stdlib>

using namespace metal;

typedef struct {
    float4 clip_pos [[position]];
    float2 uv;
} ScreenFragment;

vertex ScreenFragment
screen_vert(uint vid [[vertex_id]])
{
    // from "Vertex Shader Tricks" by AMD - GDC 2014
    ScreenFragment out;
    out.clip_pos = float4((float)(vid / 2) * 4.0 - 1.0,
                          (float)(vid % 2) * 4.0 - 1.0,
                          0.0,
                          1.0);
    out.uv = float2((float)(vid / 2) * 2.0,
                    1.0 - (float)(vid % 2) * 2.0);
    return out;
}

/*
 The range of uv: [0.0, 1.0]
 The origin of the Metal texture coord system is at the upper-left of the quad.
 */
fragment half4
screen_frag(ScreenFragment  in  [[stage_in]],
            texture2d<half> tex [[texture(0)]])
{
    constexpr sampler textureSampler (mag_filter::linear,
                                      min_filter::linear);

    half4 out_color = tex.sample(textureSampler, in.uv);
    return out_color;
}

typedef struct
{
    float4 renderedCoordinate [[position]]; // clip space
    float2 textureCoordinate;
} TextureMappingVertex;

// Projects provided vertices to corners of offscreen texture.
vertex TextureMappingVertex
quadVertexShader(unsigned int vertex_id  [[ vertex_id ]])
{
    // Triangle strip in NDC (normalized device coords).
    // The vertices' coord system has (0, 0) at the bottom left.
    float4x4 renderedCoordinates = float4x4(float4(-1.0, -1.0, 0.0, 1.0),   /// (x, y, z, w)
                                            float4( 1.0, -1.0, 0.0, 1.0),
                                            float4(-1.0,  1.0, 0.0, 1.0),
                                            float4( 1.0,  1.0, 0.0, 1.0));
    // The texture coord system has (0, 0) at the upper left
    // The s-axis is +ve right and the t-axis is +ve down
    float4x2 textureCoordinates = float4x2(float2(0.0, 1.0),                /// (s, t)
                                           float2(1.0, 1.0),
                                           float2(0.0, 0.0),
                                           float2(1.0, 0.0));
    TextureMappingVertex outVertex;
    outVertex.renderedCoordinate = renderedCoordinates[vertex_id];
    outVertex.textureCoordinate = textureCoordinates[vertex_id];
    return outVertex;
}

constexpr sampler sampl(address::clamp_to_edge,
                        filter::linear,
                        coord::normalized);

fragment half4
quadFragmentShader(TextureMappingVertex            mappingVertex  [[stage_in]],
                   texture2d<half, access::sample> colorTextures  [[texture(0)]])
{
    half4 colorFrag = colorTextures.sample(sampl,
                                           mappingVertex.textureCoordinate);
    return colorFrag;
}

/////// Kernel function code
// BT.601, which is the standard for SDTV.
constant float3x3 kColorConversion601 = float3x3(
    float3(1.164,  1.164, 1.164),
    float3(0.000, -0.392, 2.017),
    float3(1.596, -0.813, 0.000));

// BT.709, which is the standard for HDTV.
constant float3x3 kColorConversion709 = float3x3(
    float3(1.164,  1.164, 1.164),
    float3(0.000, -0.213, 2.112),
    float3(1.793, -0.533, 0.000));

constant float3 colorOffset = float3(-(16.0/255.0), -0.5, -0.5);

kernel void
YCbCrColorConversion(texture2d<float, access::read>   yTexture  [[texture(0)]],
                     texture2d<float, access::read> cbcrTexture [[texture(1)]],
                     texture2d<float, access::write> outTexture [[texture(2)]],
                     uint2                              gid     [[thread_position_in_grid]])
{
    uint width = outTexture.get_width();
    uint height = outTexture.get_height();
    uint column = gid.x;
    uint row = gid.y;
    if ((column >= width) || (row >= height)) {
        // In case the size of the texture does not match the size of the grid.
        // Return early if the pixel is out of bounds.
        return;
    }

    // The CbCr texture is 1/4 the size of the Yp texture.
    uint2 cbcrCoordinates = uint2(gid.x / 2, gid.y / 2);

    float y = yTexture.read(gid).r;
    float2 cbcr = cbcrTexture.read(cbcrCoordinates).rg;

    // yCbCr pixel
    float3 ycbcr = float3(y, cbcr);

    // Convert to an RGB pixel
    float3 rgb = kColorConversion709 * (ycbcr + colorOffset);

    outTexture.write(float4(float3(rgb), 1.0), gid);
}
