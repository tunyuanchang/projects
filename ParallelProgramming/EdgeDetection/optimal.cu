#include <iostream>
#include <cstdlib>
#include <cassert>
#include <zlib.h>
#include <png.h>

#define Z 2
#define Y 5
#define X 5
#define xBound X / 2
#define yBound Y / 2
#define SCALE 8

int read_png(const char* filename, unsigned char** image, unsigned* height, 
             unsigned* width, unsigned* channels) {

    unsigned char sig[8];
    FILE* infile;
    infile = fopen(filename, "rb");

    fread(sig, 1, 8, infile);
    if (!png_check_sig(sig, 8))
        return 1;   /* bad signature */

    png_structp png_ptr;
    png_infop info_ptr;

    png_ptr = png_create_read_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL);
    if (!png_ptr)
        return 4;   /* out of memory */
  
    info_ptr = png_create_info_struct(png_ptr);
    if (!info_ptr) {
        png_destroy_read_struct(&png_ptr, NULL, NULL);
        return 4;   /* out of memory */
    }

    png_init_io(png_ptr, infile);
    png_set_sig_bytes(png_ptr, 8);
    png_read_info(png_ptr, info_ptr);
    int bit_depth, color_type;
    png_get_IHDR(png_ptr, info_ptr, width, height, &bit_depth, &color_type, NULL, NULL, NULL);

    png_uint_32  i, rowbytes;
    png_bytep  row_pointers[*height];
    png_read_update_info(png_ptr, info_ptr);
    rowbytes = png_get_rowbytes(png_ptr, info_ptr);
    *channels = (int) png_get_channels(png_ptr, info_ptr);

    if ((*image = (unsigned char *) malloc(rowbytes * *height)) == NULL) {
        png_destroy_read_struct(&png_ptr, &info_ptr, NULL);
        return 3;
    }

    for (i = 0;  i < *height;  ++i)
        row_pointers[i] = *image + i * rowbytes;
    png_read_image(png_ptr, row_pointers);
    png_read_end(png_ptr, NULL);
    return 0;
}

void write_png(const char* filename, png_bytep image, const unsigned height, const unsigned width, 
               const unsigned channels) {
    FILE* fp = fopen(filename, "wb");
    png_structp png_ptr = png_create_write_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL);
    png_infop info_ptr = png_create_info_struct(png_ptr);
    png_init_io(png_ptr, fp);
    png_set_IHDR(png_ptr, info_ptr, width, height, 8,
                 PNG_COLOR_TYPE_RGB, PNG_INTERLACE_NONE,
                 PNG_COMPRESSION_TYPE_DEFAULT, PNG_FILTER_TYPE_DEFAULT);
    png_set_filter(png_ptr, 0, PNG_NO_FILTERS);
    png_write_info(png_ptr, info_ptr);
    png_set_compression_level(png_ptr, 1);

    png_bytep row_ptr[height];
    for (int i = 0; i < height; ++ i) {
        row_ptr[i] = image + i * width * channels * sizeof(unsigned char);
    }
    png_write_image(png_ptr, row_ptr);
    png_write_end(png_ptr, NULL);
    png_destroy_write_struct(&png_ptr, &info_ptr);
    fclose(fp);
}

__constant__ char mask[Z][Y][X] = { { { -1, -4, -6, -4, -1 },
                                        { -2, -8, -12, -8, -2 },
                                        { 0, 0, 0, 0, 0 },
                                        { 2, 8, 12, 8, 2 },
                                        { 1, 4, 6, 4, 1 } },
                                      { { -1, -2, 0, 2, 1 },
                                        { -4, -8, 0, 8, 4 },
                                        { -6, -12, 0, 12, 6 },
                                        { -4, -8, 0, 8, 4 },
                                        { -1, -2, 0, 2, 1 } } };

inline __device__ int bound_check(int val, int lower, int upper) {
    if (val >= lower && val < upper)
        return 1;
    else
        return 0;
}

__global__ void sobel(unsigned char *s, unsigned char *t, unsigned height, unsigned width, unsigned channels) {

    float val[Z][3];
    __shared__ unsigned char r[10][135];
    __shared__ unsigned char g[10][135];
    __shared__ unsigned char b[10][135];

    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;
    if(x >= width) return;
    if(y >= height) return;

    /* Shared Memory */
    #pragma unroll(5)
    for (int v = -yBound; v <= yBound; ++v) {
        if (bound_check(y + v, 0, height)) {
            r[v + yBound + threadIdx.y][threadIdx.x + 2] = s[channels * (width * (y + v) + x) + 2];
            g[v + yBound + threadIdx.y][threadIdx.x + 2] = s[channels * (width * (y + v) + x) + 1];
            b[v + yBound + threadIdx.y][threadIdx.x + 2] = s[channels * (width * (y + v) + x) + 0];

            if (threadIdx.x == 0) { // left 2
                if (x - 1 >= 0) {
                    r[v + yBound + threadIdx.y][threadIdx.x + 1] = s[channels * (width * (y + v) + x - 1) + 2];
                    g[v + yBound + threadIdx.y][threadIdx.x + 1] = s[channels * (width * (y + v) + x - 1) + 1];
                    b[v + yBound + threadIdx.y][threadIdx.x + 1] = s[channels * (width * (y + v) + x - 1) + 0];
                }

                if (x - 2 >= 0) {
                    r[v + yBound + threadIdx.y][threadIdx.x + 0] = s[channels * (width * (y + v) + x - 2) + 2];
                    g[v + yBound + threadIdx.y][threadIdx.x + 0] = s[channels * (width * (y + v) + x - 2) + 1];
                    b[v + yBound + threadIdx.y][threadIdx.x + 0] = s[channels * (width * (y + v) + x - 2) + 0];
                }
            } 
            else if (threadIdx.x == blockDim.x - 1) { // right 2
                if (x + 1 < width) {
                    r[v + yBound + threadIdx.y][threadIdx.x + 3] = s[channels * (width * (y + v) + x + 1) + 2];
                    g[v + yBound + threadIdx.y][threadIdx.x + 3] = s[channels * (width * (y + v) + x + 1) + 1];
                    b[v + yBound + threadIdx.y][threadIdx.x + 3] = s[channels * (width * (y + v) + x + 1) + 0];
                }
                if (x + 2 < width) {
                    r[v + yBound + threadIdx.y][threadIdx.x + 4] = s[channels * (width * (y + v) + x + 2) + 2];
                    g[v + yBound + threadIdx.y][threadIdx.x + 4] = s[channels * (width * (y + v) + x + 2) + 1];
                    b[v + yBound + threadIdx.y][threadIdx.x + 4] = s[channels * (width * (y + v) + x + 2) + 0];
                }
            }
        }
    }
     __syncthreads();

    /* Z axis of mask */
    #pragma unroll(2)
    for (int i = 0; i < Z; ++i) {
        val[i][2] = 0.;
        val[i][1] = 0.;
        val[i][0] = 0.;
    
        /* Y and X axis of mask */
        for (int v = -yBound; v <= yBound; ++v) {
            for (int u = -xBound; u <= xBound; ++u) {
                if (bound_check(x + u, 0, width) && bound_check(y + v, 0, height)) {
                    const unsigned char R = r[v+yBound + threadIdx.y][threadIdx.x + 2 + u];
                    const unsigned char G = g[v+yBound + threadIdx.y][threadIdx.x + 2 + u];
                    const unsigned char B = b[v+yBound + threadIdx.y][threadIdx.x + 2 + u];
                    val[i][2] += R * mask[i][u + xBound][v + yBound];
                    val[i][1] += G * mask[i][u + xBound][v + yBound];
                    val[i][0] += B * mask[i][u + xBound][v + yBound];
                }
            }
        }
    }
    float totalR = 0.;
    float totalG = 0.;
    float totalB = 0.;
    for (int i = 0; i < Z; ++i) {
        totalR += val[i][2] * val[i][2];
        totalG += val[i][1] * val[i][1];
        totalB += val[i][0] * val[i][0];
    }
    totalR = sqrt(totalR) / SCALE;
    totalG = sqrt(totalG) / SCALE;
    totalB = sqrt(totalB) / SCALE;
    const unsigned char cR = (totalR > 255.) ? 255 : totalR;
    const unsigned char cG = (totalG > 255.) ? 255 : totalG;
    const unsigned char cB = (totalB > 255.) ? 255 : totalB;
    t[channels * (width * y + x) + 2] = cR;
    t[channels * (width * y + x) + 1] = cG;
    t[channels * (width * y + x) + 0] = cB;
}


int main(int argc, char **argv) {
    assert(argc == 3);
    unsigned height, width, channels;
    unsigned char *src = NULL, *dst;
    unsigned char *dsrc, *ddst;

    /* read the image to src, and get height, width, channels */
    if (read_png(argv[1], &src, &height, &width, &channels)) {
        std::cerr << "Error in read png" << std::endl;
        return -1;
    }

    dst = (unsigned char *)malloc(height * width * channels * sizeof(unsigned char));
    cudaHostRegister(src, height * width * channels * sizeof(unsigned char), cudaHostRegisterDefault);

    // cudaMalloc(...) for device src and device dst
    cudaMalloc(&dsrc, height * width * channels * sizeof(unsigned char));
    cudaMalloc(&ddst, height * width * channels * sizeof(unsigned char));

    // cudaMemcpy(...) copy source image to device (mask matrix if necessary)
    cudaMemcpy(dsrc, src, height * width * channels * sizeof(unsigned char), cudaMemcpyHostToDevice);

    // decide to use how many blocks and threads
    dim3 num_threads(128, 4);
    dim3 num_blocks((width + 128 - 1) / 128, (height + 4 - 1) / 4);

    // launch cuda kernel
    sobel << <num_blocks, num_threads>>> (dsrc, ddst, height, width, channels);

    // cudaMemcpy(...) copy result image to host
    cudaMemcpy(dst, ddst, height * width * channels * sizeof(unsigned char), cudaMemcpyDeviceToHost);

    write_png(argv[2], dst, height, width, channels);
    free(src);
    free(dst);
    cudaFree(dsrc);
    cudaFree(ddst);
    return 0;
}

