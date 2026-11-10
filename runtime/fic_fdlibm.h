/* fic_fdlibm.h -- the Float functions of V8 (src/base/ieee754.cc), which are fdlibm (Sun, 1993) with a few changes: so that
   Math.sin, Math.exp, Math.pow, ... of node give the same digits as the compiled program (decision L18; every digit of a Float is
   printed). Differential test against node: tools in runtime/fdlibm_test.py. Needs -ffp-contract=off (CLAUDE.md).
   Copyright (C) 1993 by Sun Microsystems, Inc. Permission to use, copy, modify, and distribute this software is freely granted,
   provided that this notice is preserved. (Parts: musl libm, MIT licence, for the kernels that are identical in FreeBSD msun.) */
#include <math.h>
#include <stdint.h>
#include <string.h>

#define FIC_FD_P2M24 5.9604644775390625e-08
#define FIC_FD_P224 16777216.0
#define FIC_FD_P21023 8.98846567431158e307
#define FIC_FD_P254 18014398509481984.0

static uint32_t fic_fd_hi(double x) { uint64_t u; memcpy(&u, &x, 8); return (uint32_t)(u >> 32); }
static uint32_t fic_fd_lo(double x) { uint64_t u; memcpy(&u, &x, 8); return (uint32_t)u; }
static double fic_fd_with_hi(double x, uint32_t h) { uint64_t u; memcpy(&u, &x, 8); u = (u & 0xffffffffULL) | ((uint64_t)h << 32); memcpy(&x, &u, 8); return x; }
static double fic_fd_with_lo(double x, uint32_t l) { uint64_t u; memcpy(&u, &x, 8); u = (u & 0xffffffff00000000ULL) | l; memcpy(&x, &u, 8); return x; }
static double fic_fd_from(uint32_t h, uint32_t l) { uint64_t u = ((uint64_t)h << 32) | l; double x; memcpy(&x, &u, 8); return x; }
#define GET_HIGH_WORD(i, d) ((i) = fic_fd_hi(d))
#define GET_LOW_WORD(i, d) ((i) = fic_fd_lo(d))
#define SET_LOW_WORD(d, v) ((d) = fic_fd_with_lo((d), (uint32_t)(v)))
#define SET_HIGH_WORD(d, v) ((d) = fic_fd_with_hi((d), (uint32_t)(v)))
#define EXTRACT_WORDS(h, l, d) do { (h) = (int32_t)fic_fd_hi(d); (l) = fic_fd_lo(d); } while (0)

static double fic_fd_scalbn(double x, int n) {    /* exact scaling (x * 2^n) with one rounding at most, as scalbn */
  double y = x;
  if (n > 1023) { y *= 0x1p1023; n -= 1023; if (n > 1023) { y *= 0x1p1023; n -= 1023; if (n > 1023) n = 1023; } }
  else if (n < -1022) { y *= 0x1p-1022 * 0x1p53; n += 1022 - 53; if (n < -1022) { y *= 0x1p-1022 * 0x1p53; n += 1022 - 53; if (n < -1022) n = -1022; } }
  return y * fic_fd_from((uint32_t)(0x3ff + n) << 20, 0);
}



static const int fic_fd_init_jk[] = {3,4,4,6}; 
static const int32_t fic_fd_ipio2[] = {
0xA2F983, 0x6E4E44, 0x1529FC, 0x2757D1, 0xF534DD, 0xC0DB62,
0x95993C, 0x439041, 0xFE5163, 0xABDEBB, 0xC561B7, 0x246E3A,
0x424DD2, 0xE00649, 0x2EEA09, 0xD1921C, 0xFE1DEB, 0x1CB129,
0xA73EE8, 0x8235F5, 0x2EBB44, 0x84E99C, 0x7026B4, 0x5F7E41,
0x3991D6, 0x398353, 0x39F49C, 0x845F8B, 0xBDF928, 0x3B1FF8,
0x97FFDE, 0x05980F, 0xEF2F11, 0x8B5A0A, 0x6D1F6D, 0x367ECF,
0x27CB09, 0xB74F46, 0x3F669E, 0x5FEA2D, 0x7527BA, 0xC7EBE5,
0xF17B3D, 0x0739F7, 0x8A5292, 0xEA6BFB, 0x5FB11F, 0x8D5D08,
0x560330, 0x46FC7B, 0x6BABF0, 0xCFBC20, 0x9AF436, 0x1DA9E3,
0x91615E, 0xE61B08, 0x659985, 0x5F14A0, 0x68408D, 0xFFD880,
0x4D7327, 0x310606, 0x1556CA, 0x73A8C9, 0x60E27B, 0xC08C6B,
#if LDBL_MAX_EXP > 1024
0x47C419, 0xC367CD, 0xDCE809, 0x2A8359, 0xC4768B, 0x961CA6,
0xDDAF44, 0xD15719, 0x053EA5, 0xFF0705, 0x3F7E33, 0xE832C2,
0xDE4F98, 0x327DBB, 0xC33D26, 0xEF6B1E, 0x5EF89F, 0x3A1F35,
0xCAF27F, 0x1D87F1, 0x21907C, 0x7C246A, 0xFA6ED5, 0x772D30,
0x433B15, 0xC614B5, 0x9D19C3, 0xC2C4AD, 0x414D2C, 0x5D000C,
0x467D86, 0x2D71E3, 0x9AC69B, 0x006233, 0x7CD2B4, 0x97A7B4,
0xD55537, 0xF63ED7, 0x1810A3, 0xFC764D, 0x2A9D64, 0xABD770,
0xF87C63, 0x57B07A, 0xE71517, 0x5649C0, 0xD9D63B, 0x3884A7,
0xCB2324, 0x778AD6, 0x23545A, 0xB91F00, 0x1B0AF1, 0xDFCE19,
0xFF319F, 0x6A1E66, 0x615799, 0x47FBAC, 0xD87F7E, 0xB76522,
0x89E832, 0x60BFE6, 0xCDC4EF, 0x09366C, 0xD43F5D, 0xD7DE16,
0xDE3B58, 0x929BDE, 0x2822D2, 0xE88628, 0x4D58E2, 0x32CAC6,
0x16E308, 0xCB7DE0, 0x50C017, 0xA71DF3, 0x5BE018, 0x34132E,
0x621283, 0x014883, 0x5B8EF5, 0x7FB0AD, 0xF2E91E, 0x434A48,
0xD36710, 0xD8DDAA, 0x425FAE, 0xCE616A, 0xA4280A, 0xB499D3,
0xF2A606, 0x7F775C, 0x83C2A3, 0x883C61, 0x78738A, 0x5A8CAF,
0xBDD76F, 0x63A62D, 0xCBBFF4, 0xEF818D, 0x67C126, 0x45CA55,
0x36D9CA, 0xD2A828, 0x8D61C2, 0x77C912, 0x142604, 0x9B4612,
0xC459C4, 0x44C5C8, 0x91B24D, 0xF31700, 0xAD43D4, 0xE54929,
0x10D5FD, 0xFCBE00, 0xCC941E, 0xEECE70, 0xF53E13, 0x80F1EC,
0xC3E7B3, 0x28F8C7, 0x940593, 0x3E71C1, 0xB3092E, 0xF3450B,
0x9C1288, 0x7B20AB, 0x9FB52E, 0xC29247, 0x2F327B, 0x6D550C,
0x90A772, 0x1FE76B, 0x96CB31, 0x4A1679, 0xE27941, 0x89DFF4,
0x9794E8, 0x84E6E2, 0x973199, 0x6BED88, 0x365F5F, 0x0EFDBB,
0xB49A48, 0x6CA467, 0x427271, 0x325D8D, 0xB8159F, 0x09E5BC,
0x25318D, 0x3974F7, 0x1C0530, 0x010C0D, 0x68084B, 0x58EE2C,
0x90AA47, 0x02E774, 0x24D6BD, 0xA67DF7, 0x72486E, 0xEF169F,
0xA6948E, 0xF691B4, 0x5153D1, 0xF20ACF, 0x339820, 0x7E4BF5,
0x6863B2, 0x5F3EDD, 0x035D40, 0x7F8985, 0x295255, 0xC06437,
0x10D86D, 0x324832, 0x754C5B, 0xD4714E, 0x6E5445, 0xC1090B,
0x69F52A, 0xD56614, 0x9D0727, 0x50045D, 0xDB3BB4, 0xC576EA,
0x17F987, 0x7D6B49, 0xBA271D, 0x296996, 0xACCCC6, 0x5414AD,
0x6AE290, 0x89D988, 0x50722C, 0xBEA404, 0x940777, 0x7030F3,
0x27FC00, 0xA871EA, 0x49C266, 0x3DE064, 0x83DD97, 0x973FA3,
0xFD9443, 0x8C860D, 0xDE4131, 0x9D3992, 0x8C70DD, 0xE7B717,
0x3BDF08, 0x2B3715, 0xA0805C, 0x93805A, 0x921110, 0xD8E80F,
0xAF806C, 0x4BFFDB, 0x0F9038, 0x761859, 0x15A562, 0xBBCB61,
0xB989C7, 0xBD4010, 0x04F2D2, 0x277549, 0xF6B6EB, 0xBB22DB,
0xAA140A, 0x2F2689, 0x768364, 0x333B09, 0x1A940E, 0xAA3A51,
0xC2A31D, 0xAEEDAF, 0x12265C, 0x4DC26D, 0x9C7A2D, 0x9756C0,
0x833F03, 0xF6F009, 0x8C402B, 0x99316D, 0x07B439, 0x15200C,
0x5BC3D8, 0xC492F5, 0x4BADC6, 0xA5CA4E, 0xCD37A7, 0x36A9E6,
0x9492AB, 0x6842DD, 0xDE6319, 0xEF8C76, 0x528B68, 0x37DBFC,
0xABA1AE, 0x3115DF, 0xA1AE00, 0xDAFB0C, 0x664D64, 0xB705ED,
0x306529, 0xBF5657, 0x3AFF47, 0xB9F96A, 0xF3BE75, 0xDF9328,
0x3080AB, 0xF68C66, 0x15CB04, 0x0622FA, 0x1DE4D9, 0xA4B33D,
0x8F1B57, 0x09CD36, 0xE9424E, 0xA4BE13, 0xB52333, 0x1AAAF0,
0xA8654F, 0xA5C1D2, 0x0F3F0B, 0xCD785B, 0x76F923, 0x048B7B,
0x721789, 0x53A6C6, 0xE26E6F, 0x00EBEF, 0x584A9B, 0xB7DAC4,
0xBA66AA, 0xCFCF76, 0x1D02D1, 0x2DF1B1, 0xC1998C, 0x77ADC3,
0xDA4886, 0xA05DF7, 0xF480C6, 0x2FF0AC, 0x9AECDD, 0xBC5C3F,
0x6DDED0, 0x1FC790, 0xB6DB2A, 0x3A25A3, 0x9AAF00, 0x9353AD,
0x0457B6, 0xB42D29, 0x7E804B, 0xA707DA, 0x0EAA76, 0xA1597B,
0x2A1216, 0x2DB7DC, 0xFDE5FA, 0xFEDB89, 0xFDBE89, 0x6C76E4,
0xFCA906, 0x70803E, 0x156E85, 0xFF87FD, 0x073E28, 0x336761,
0x86182A, 0xEABD4D, 0xAFE7B3, 0x6E6D8F, 0x396795, 0x5BBF31,
0x48D784, 0x16DF30, 0x432DC7, 0x356125, 0xCE70C9, 0xB8CB30,
0xFD6CBF, 0xA200A4, 0xE46C05, 0xA0DD5A, 0x476F21, 0xD21262,
0x845CB9, 0x496170, 0xE0566B, 0x015299, 0x375550, 0xB7D51E,
0xC4F133, 0x5F6E13, 0xE4305D, 0xA92E85, 0xC3B21D, 0x3632A1,
0xA4B708, 0xD4B1EA, 0x21F716, 0xE4698F, 0x77FF27, 0x80030C,
0x2D408D, 0xA0CD4F, 0x99A520, 0xD3A2B3, 0x0A5D2F, 0x42F9B4,
0xCBDA11, 0xD0BE7D, 0xC1DB9B, 0xBD17AB, 0x81A2CA, 0x5C6A08,
0x17552E, 0x550027, 0xF0147F, 0x8607E1, 0x640B14, 0x8D4196,
0xDEBE87, 0x2AFDDA, 0xB6256B, 0x34897B, 0xFEF305, 0x9EBFB9,
0x4F6A68, 0xA82A4A, 0x5AC44F, 0xBCF82D, 0x985AD7, 0x95C7F4,
0x8D4D0D, 0xA63A20, 0x5F57A4, 0xB13F14, 0x953880, 0x0120CC,
0x86DD71, 0xB6DEC9, 0xF560BF, 0x11654D, 0x6B0701, 0xACB08C,
0xD0C0B2, 0x485551, 0x0EFB1E, 0xC37295, 0x3B06A3, 0x3540C0,
0x7BDC06, 0xCC45E0, 0xFA294E, 0xC8CAD6, 0x41F3E8, 0xDE647C,
0xD8649B, 0x31BED9, 0xC397A4, 0xD45877, 0xC5E369, 0x13DAF0,
0x3C3ABA, 0x461846, 0x5F7555, 0xF5BDD2, 0xC6926E, 0x5D2EAC,
0xED440E, 0x423E1C, 0x87C461, 0xE9FD29, 0xF3D6E7, 0xCA7C22,
0x35916F, 0xC5E008, 0x8DD7FF, 0xE26A6E, 0xC6FDB0, 0xC10893,
0x745D7C, 0xB2AD6B, 0x9D6ECD, 0x7B723E, 0x6A11C6, 0xA9CFF7,
0xDF7329, 0xBAC9B5, 0x5100B7, 0x0DB2E2, 0x24BA74, 0x607DE5,
0x8AD874, 0x2C150D, 0x0C1881, 0x94667E, 0x162901, 0x767A9F,
0xBEFDFD, 0xEF4556, 0x367ED9, 0x13D9EC, 0xB9BA8B, 0xFC97C4,
0x27A831, 0xC36EF1, 0x36C594, 0x56A8D8, 0xB5A8B4, 0x0ECCCF,
0x2D8912, 0x34576F, 0x89562C, 0xE3CE99, 0xB920D6, 0xAA5E6B,
0x9C2A3E, 0xCC5F11, 0x4A0BFD, 0xFBF4E1, 0x6D3B8E, 0x2C86E2,
0x84D4E9, 0xA9B4FC, 0xD1EEEF, 0xC9352E, 0x61392F, 0x442138,
0xC8D91B, 0x0AFC81, 0x6A4AFB, 0xD81C2F, 0x84B453, 0x8C994E,
0xCC2254, 0xDC552A, 0xD6C6C0, 0x96190B, 0xB8701A, 0x649569,
0x605A26, 0xEE523F, 0x0F117F, 0x11B5F4, 0xF5CBFC, 0x2DBC34,
0xEEBC34, 0xCC5DE8, 0x605EDD, 0x9B8E67, 0xEF3392, 0xB817C9,
0x9B5861, 0xBC57E1, 0xC68351, 0x103ED8, 0x4871DD, 0xDD1C2D,
0xA118AF, 0x462C21, 0xD7F359, 0x987AD9, 0xC0549E, 0xFA864F,
0xFC0656, 0xAE79E5, 0x362289, 0x22AD38, 0xDC9367, 0xAAE855,
0x382682, 0x9BE7CA, 0xA40D51, 0xB13399, 0x0ED7A9, 0x480569,
0xF0B265, 0xA7887F, 0x974C88, 0x36D1F9, 0xB39221, 0x4A827B,
0x21CF98, 0xDC9F40, 0x5547DC, 0x3A74E1, 0x42EB67, 0xDF9DFE,
0x5FD45E, 0xA4677B, 0x7AACBA, 0xA2F655, 0x23882B, 0x55BA41,
0x086E59, 0x862A21, 0x834739, 0xE6E389, 0xD49EE5, 0x40FB49,
0xE956FF, 0xCA0F1C, 0x8A59C5, 0x2BFA94, 0xC5C1D3, 0xCFC50F,
0xAE5ADB, 0x86C547, 0x624385, 0x3B8621, 0x94792C, 0x876110,
0x7B4C2A, 0x1A2C80, 0x12BF43, 0x902688, 0x893C78, 0xE4C4A8,
0x7BDBE5, 0xC23AC4, 0xEAF426, 0x8A67F7, 0xBF920D, 0x2BA365,
0xB1933D, 0x0B7CBD, 0xDC51A4, 0x63DD27, 0xDDE169, 0x19949A,
0x9529A8, 0x28CE68, 0xB4ED09, 0x209F44, 0xCA984E, 0x638270,
0x237C7E, 0x32B90F, 0x8EF5A7, 0xE75614, 0x08F121, 0x2A9DB5,
0x4D7E6F, 0x5119A5, 0xABF9B5, 0xD6DF82, 0x61DD96, 0x023616,
0x9F3AC4, 0xA1A283, 0x6DED72, 0x7A8D39, 0xA9B882, 0x5C326B,
0x5B2746, 0xED3400, 0x7700D2, 0x55F4FC, 0x4D5901, 0x8071E0,
#endif
};
static const double fic_fd_PIo2[] = {
  1.57079625129699707031e+00, 
  7.54978941586159635335e-08, 
  5.39030252995776476554e-15, 
  3.28200341580791294123e-22, 
  1.27065575308067607349e-29, 
  1.22933308981111328932e-36, 
  2.73370053816464559624e-44, 
  2.16741683877804819444e-51, 
};
static int fic_fd_rem_pio2_large(double *x, double *y, int e0, int nx, int prec)
{
	int32_t jz,jx,jv,jp,jk,carry,n,iq[20],i,j,k,m,q0,ih;
	double z,fw,f[20],fq[20] = {0},q[20];
	jk = fic_fd_init_jk[prec];
	jp = jk;
	jx = nx-1;
	jv = (e0-3)/24;  if(jv<0) jv=0;
	q0 = e0-24*(jv+1);
	j = jv-jx; m = jx+jk;
	for (i=0; i<=m; i++,j++)
		f[i] = j<0 ? 0.0 : (double)fic_fd_ipio2[j];
	for (i=0; i<=jk; i++) {
		for (j=0,fw=0.0; j<=jx; j++)
			fw += x[j]*f[jx+i-j];
		q[i] = fw;
	}
	jz = jk;
recompute:
	for (i=0,j=jz,z=q[jz]; j>0; i++,j--) {
		fw    = (double)(int32_t)(FIC_FD_P2M24*z);
		iq[i] = (int32_t)(z - FIC_FD_P224*fw);
		z     = q[j-1]+fw;
	}
	z  = fic_fd_scalbn(z,q0);       
	z -= 8.0*floor(z*0.125); 
	n  = (int32_t)z;
	z -= (double)n;
	ih = 0;
	if (q0 > 0) {  
		i  = iq[jz-1]>>(24-q0); n += i;
		iq[jz-1] -= i<<(24-q0);
		ih = iq[jz-1]>>(23-q0);
	}
	else if (q0 == 0) ih = iq[jz-1]>>23;
	else if (z >= 0.5) ih = 2;
	if (ih > 0) {  
		n += 1; carry = 0;
		for (i=0; i<jz; i++) {  
			j = iq[i];
			if (carry == 0) {
				if (j != 0) {
					carry = 1;
					iq[i] = 0x1000000 - j;
				}
			} else
				iq[i] = 0xffffff - j;
		}
		if (q0 > 0) {  
			switch(q0) {
			case 1:
				iq[jz-1] &= 0x7fffff; break;
			case 2:
				iq[jz-1] &= 0x3fffff; break;
			}
		}
		if (ih == 2) {
			z = 1.0 - z;
			if (carry != 0)
				z -= fic_fd_scalbn(1.0,q0);
		}
	}
	if (z == 0.0) {
		j = 0;
		for (i=jz-1; i>=jk; i--) j |= iq[i];
		if (j == 0) {  
			for (k=1; iq[jk-k]==0; k++);  
			for (i=jz+1; i<=jz+k; i++) {  
				f[jx+i] = (double)fic_fd_ipio2[jv+i];
				for (j=0,fw=0.0; j<=jx; j++)
					fw += x[j]*f[jx+i-j];
				q[i] = fw;
			}
			jz += k;
			goto recompute;
		}
	}
	if (z == 0.0) {
		jz -= 1;
		q0 -= 24;
		while (iq[jz] == 0) {
			jz--;
			q0 -= 24;
		}
	} else { 
		z = fic_fd_scalbn(z,-q0);
		if (z >= FIC_FD_P224) {
			fw = (double)(int32_t)(FIC_FD_P2M24*z);
			iq[jz] = (int32_t)(z - FIC_FD_P224*fw);
			jz += 1;
			q0 += 24;
			iq[jz] = (int32_t)fw;
		} else
			iq[jz] = (int32_t)z;
	}
	fw = fic_fd_scalbn(1.0,q0);
	for (i=jz; i>=0; i--) {
		q[i] = fw*(double)iq[i];
		fw *= FIC_FD_P2M24;
	}
	for(i=jz; i>=0; i--) {
		for (fw=0.0,k=0; k<=jp && k<=jz-i; k++)
			fw += fic_fd_PIo2[k]*q[i+k];
		fq[jz-i] = fw;
	}
	switch(prec) {
	case 0:
		fw = 0.0;
		for (i=jz; i>=0; i--)
			fw += fq[i];
		y[0] = ih==0 ? fw : -fw;
		break;
	case 1:
	case 2:
		fw = 0.0;
		for (i=jz; i>=0; i--)
			fw += fq[i];
		// TODO: drop excess precision here once double_t is used
		fw = (double)fw;
		y[0] = ih==0 ? fw : -fw;
		fw = fq[0]-fw;
		for (i=1; i<=jz; i++)
			fw += fq[i];
		y[1] = ih==0 ? fw : -fw;
		break;
	case 3:  
		for (i=jz; i>0; i--) {
			fw      = fq[i-1]+fq[i];
			fq[i]  += fq[i-1]-fw;
			fq[i-1] = fw;
		}
		for (i=jz; i>1; i--) {
			fw      = fq[i-1]+fq[i];
			fq[i]  += fq[i-1]-fw;
			fq[i-1] = fw;
		}
		for (fw=0.0,i=jz; i>=2; i--)
			fw += fq[i];
		if (ih==0) {
			y[0] =  fq[0]; y[1] =  fq[1]; y[2] =  fw;
		} else {
			y[0] = -fq[0]; y[1] = -fq[1]; y[2] = -fw;
		}
	}
	return n&7;
}


/* ---- sin, cos, tan: fdlibm k_sin, k_cos, k_tan, e_rem_pio2 (the original versions) ---- */
static double fic_fd_kernel_sin(double x, double y, int iy) {
  static const double S1 = -1.66666666666666324348e-01, S2 = 8.33333333332248946124e-03, S3 = -1.98412698298579493134e-04,
    S4 = 2.75573137070700676789e-06, S5 = -2.50507602534068634195e-08, S6 = 1.58969099521155010221e-10;
  double z, r, v; int32_t ix;
  GET_HIGH_WORD(ix, x); ix &= 0x7fffffff;
  if (ix < 0x3e400000) { if ((int)x == 0) return x; }
  z = x * x; v = z * x;
  r = S2 + z * (S3 + z * (S4 + z * (S5 + z * S6)));
  if (iy == 0) return x + v * (S1 + z * r);
  return x - ((z * (0.5 * y - v * r) - y) - v * S1);
}

static double fic_fd_kernel_cos(double x, double y) {
  static const double C1 = 4.16666666666666019037e-02, C2 = -1.38888888888741095749e-03, C3 = 2.48015872894767294178e-05,
    C4 = -2.75573143513906633035e-07, C5 = 2.08757232129817482790e-09, C6 = -1.13596475577881948265e-11;
  double a, hz, z, r, qx = 0; int32_t ix;
  GET_HIGH_WORD(ix, x); ix &= 0x7fffffff;
  if (ix < 0x3e400000) { if ((int)x == 0) return 1.0; }
  z = x * x;
  r = z * (C1 + z * (C2 + z * (C3 + z * (C4 + z * (C5 + z * C6)))));
  if (ix < 0x3FD33333) return 1.0 - (0.5 * z - (z * r - x * y));
  if (ix > 0x3fe90000) qx = 0.28125; else qx = fic_fd_from((uint32_t)(ix - 0x00200000), 0);
  hz = 0.5 * z - qx; a = 1.0 - qx;
  return a - (hz - (z * r - x * y));
}

static double fic_fd_kernel_tan(double x, double y, int iy) {
  static const double T[] = { 3.33333333333334091986e-01, 1.33333333333201242699e-01, 5.39682539762260521377e-02, 2.18694882948595424599e-02,
    8.86323982359930005737e-03, 3.59207910759131235356e-03, 1.45620945432529025516e-03, 5.88041240820264096874e-04, 2.46463134818469906812e-04,
    7.81794442939557092300e-05, 7.14072491382608190305e-05, -1.85586374855275456654e-05, 2.59073051863633712884e-05 };
  static const double pio4 = 7.85398163397448278999e-01, pio4lo = 3.06161699786838301793e-17;
  double z, r, v, w, s; int32_t ix, hx;
  GET_HIGH_WORD(hx, x); ix = hx & 0x7fffffff;
  if (ix < 0x3e300000) {
    if ((int)x == 0) {
      uint32_t low; GET_LOW_WORD(low, x);
      if (((ix | low) | (iy + 1)) == 0) return 1.0 / fabs(x);
      if (iy == 1) return x;
      { double a, t; z = w = x + y; SET_LOW_WORD(z, 0); v = y - (z - x); t = a = -1.0 / w; SET_LOW_WORD(t, 0); s = 1.0 + t * z; return t + a * (s + t * v); }
    }
  }
  if (ix >= 0x3FE59428) {
    if (hx < 0) { x = -x; y = -y; }
    z = pio4 - x; w = pio4lo - y; x = z + w; y = 0.0;
  }
  z = x * x; w = z * z;
  r = T[1] + w * (T[3] + w * (T[5] + w * (T[7] + w * (T[9] + w * T[11]))));
  v = z * (T[2] + w * (T[4] + w * (T[6] + w * (T[8] + w * (T[10] + w * T[12])))));
  s = z * x;
  r = y + z * (s * (r + v) + y);
  r += T[0] * s;
  w = x + r;
  if (ix >= 0x3FE59428) {
    v = (double)iy;
    return (double)(1 - ((hx >> 30) & 2)) * (v - 2.0 * (x - (w * w / (w + v) - r)));
  }
  if (iy == 1) return w;
  { double a, t; z = w; SET_LOW_WORD(z, 0); v = r - (z - x); t = a = -1.0 / w; SET_LOW_WORD(t, 0); s = 1.0 + t * z; return t + a * (s + t * v); }
}

static int fic_fd_rem_pio2(double x, double *y) {
  static const double half = 0.5, two24 = 1.67772160000000000000e+07, invpio2 = 6.36619772367581382433e-01,
    pio2_1 = 1.57079632673412561417e+00, pio2_1t = 6.07710050650619224932e-11, pio2_2 = 6.07710050630396597660e-11,
    pio2_2t = 2.02226624879595063154e-21, pio2_3 = 2.02226624871116645580e-21, pio2_3t = 8.47842766036889956997e-32;
  static const int32_t npio2_hw[] = {
    0x3FF921FB, 0x400921FB, 0x4012D97C, 0x401921FB, 0x401F6A7A, 0x4022D97C, 0x4025FDBB, 0x402921FB, 0x402C463A, 0x402F6A7A, 0x4031475C,
    0x4032D97C, 0x40346B9C, 0x4035FDBB, 0x40378FDB, 0x403921FB, 0x403AB41B, 0x403C463A, 0x403DD85A, 0x403F6A7A, 0x40407E4C, 0x4041475C,
    0x4042106C, 0x4042D97C, 0x4043A28C, 0x40446B9C, 0x404534AC, 0x4045FDBB, 0x4046C6CB, 0x40478FDB, 0x404858EB, 0x404921FB };
  double z = 0, w, t, r, fn; double tx[3]; int32_t e0, i, j, nx, n, ix, hx; uint32_t low;
  GET_HIGH_WORD(hx, x); ix = hx & 0x7fffffff;
  if (ix <= 0x3fe921fb) { y[0] = x; y[1] = 0; return 0; }
  if (ix < 0x4002d97c) {
    if (hx > 0) {
      z = x - pio2_1;
      if (ix != 0x3ff921fb) { y[0] = z - pio2_1t; y[1] = (z - y[0]) - pio2_1t; }
      else { z -= pio2_2; y[0] = z - pio2_2t; y[1] = (z - y[0]) - pio2_2t; }
      return 1;
    } else {
      z = x + pio2_1;
      if (ix != 0x3ff921fb) { y[0] = z + pio2_1t; y[1] = (z - y[0]) + pio2_1t; }
      else { z += pio2_2; y[0] = z + pio2_2t; y[1] = (z - y[0]) + pio2_2t; }
      return -1;
    }
  }
  if (ix <= 0x413921fb) {
    t = fabs(x);
    n = (int32_t)(t * invpio2 + half);
    fn = (double)n;
    r = t - fn * pio2_1;
    w = fn * pio2_1t;
    if (n < 32 && ix != npio2_hw[n - 1]) { y[0] = r - w; }
    else {
      uint32_t high;
      j = ix >> 20;
      y[0] = r - w;
      GET_HIGH_WORD(high, y[0]);
      i = j - ((high >> 20) & 0x7ff);
      if (i > 16) {
        t = r; w = fn * pio2_2; r = t - w; w = fn * pio2_2t - ((t - r) - w); y[0] = r - w;
        GET_HIGH_WORD(high, y[0]);
        i = j - ((high >> 20) & 0x7ff);
        if (i > 49) { t = r; w = fn * pio2_3; r = t - w; w = fn * pio2_3t - ((t - r) - w); y[0] = r - w; }
      }
    }
    y[1] = (r - y[0]) - w;
    if (hx < 0) { y[0] = -y[0]; y[1] = -y[1]; return -n; }
    return n;
  }
  if (ix >= 0x7ff00000) { y[0] = y[1] = x - x; return 0; }
  GET_LOW_WORD(low, x);
  e0 = (ix >> 20) - 1046;
  z = fic_fd_from((uint32_t)(ix - (int32_t)((uint32_t)e0 << 20)), low);
  for (i = 0; i < 2; i++) { tx[i] = (double)((int32_t)z); z = (z - tx[i]) * two24; }
  tx[2] = z;
  nx = 3;
  while (tx[nx - 1] == 0.0) nx--;
  n = fic_fd_rem_pio2_large(tx, y, e0, nx, 1);
  if (hx < 0) { y[0] = -y[0]; y[1] = -y[1]; return -n; }
  return n;
}

static double fic_fd_sin(double x) {
  double y[2]; int32_t n, ix;
  GET_HIGH_WORD(ix, x); ix &= 0x7fffffff;
  if (ix <= 0x3fe921fb) return fic_fd_kernel_sin(x, 0.0, 0);
  if (ix >= 0x7ff00000) return x - x;
  n = fic_fd_rem_pio2(x, y);
  switch (n & 3) {
    case 0: return fic_fd_kernel_sin(y[0], y[1], 1);
    case 1: return fic_fd_kernel_cos(y[0], y[1]);
    case 2: return -fic_fd_kernel_sin(y[0], y[1], 1);
    default: return -fic_fd_kernel_cos(y[0], y[1]);
  }
}

static double fic_fd_cos(double x) {
  double y[2]; int32_t n, ix;
  GET_HIGH_WORD(ix, x); ix &= 0x7fffffff;
  if (ix <= 0x3fe921fb) return fic_fd_kernel_cos(x, 0.0);
  if (ix >= 0x7ff00000) return x - x;
  n = fic_fd_rem_pio2(x, y);
  switch (n & 3) {
    case 0: return fic_fd_kernel_cos(y[0], y[1]);
    case 1: return -fic_fd_kernel_sin(y[0], y[1], 1);
    case 2: return -fic_fd_kernel_cos(y[0], y[1]);
    default: return fic_fd_kernel_sin(y[0], y[1], 1);
  }
}

static double fic_fd_tan(double x) {
  double y[2]; int32_t n, ix;
  GET_HIGH_WORD(ix, x); ix &= 0x7fffffff;
  if (ix <= 0x3fe921fb) return fic_fd_kernel_tan(x, 0.0, 1);
  if (ix >= 0x7ff00000) return x - x;
  n = fic_fd_rem_pio2(x, y);
  return fic_fd_kernel_tan(y[0], y[1], 1 - ((n & 1) << 1));
}



static const double
em1_o_threshold = 7.09782712893383973096e+02, 
em1_ln2_hi      = 6.93147180369123816490e-01, 
em1_ln2_lo      = 1.90821492927058770002e-10, 
em1_invln2      = 1.44269504088896338700e+00, 
em1_Q1 = -3.33333333333331316428e-02, 
em1_Q2 =  1.58730158725481460165e-03, 
em1_Q3 = -7.93650757867487942473e-05, 
em1_Q4 =  4.00821782732936239552e-06, 
em1_Q5 = -2.01099218183624371326e-07; 
static double fic_fd_expm1(double x)
{
	double y,hi,lo,c=0,t,e,hxs,hfx,r1,twopk;
	union {double f; uint64_t i;} u = {x};
	uint32_t hx = u.i>>32 & 0x7fffffff;
	int k = 0, sign = u.i>>63;
	if (hx >= 0x4043687A) {  
		if ((x != x))
			return x;
		if (sign)
			return -1;
		if (x > em1_o_threshold) {
			x *= FIC_FD_P21023;
			return x;
		}
	}
	if (hx > 0x3fd62e42) {  
		if (hx < 0x3FF0A2B2) {  
			if (!sign) {
				hi = x - em1_ln2_hi;
				lo = em1_ln2_lo;
				k =  1;
			} else {
				hi = x + em1_ln2_hi;
				lo = -em1_ln2_lo;
				k = -1;
			}
		} else {
			k  = em1_invln2*x + (sign ? -0.5 : 0.5);
			t  = k;
			hi = x - t*em1_ln2_hi;  
			lo = t*em1_ln2_lo;
		}
		x = hi-lo;
		c = (hi-x)-lo;
	} else if (hx < 0x3c900000) {  
		return x;
	} else
		k = 0;
	hfx = 0.5*x;
	hxs = x*hfx;
	r1 = 1.0+hxs*(em1_Q1+hxs*(em1_Q2+hxs*(em1_Q3+hxs*(em1_Q4+hxs*em1_Q5))));
	t  = 3.0-r1*hfx;
	e  = hxs*((r1-t)/(6.0 - x*t));
	if (k == 0)   
		return x - (x*e-hxs);
	e  = x*(e-c) - c;
	e -= hxs;
	if (k == -1)
		return 0.5*(x-e) - 0.5;
	if (k == 1) {
		if (x < -0.25)
			return -2.0*(e-(x+0.5));
		return 1.0+2.0*(x-e);
	}
	u.i = (uint64_t)(0x3ff + k)<<52;  
	twopk = u.f;
	if (k < 0 || k > 56) {  
		y = x - e + 1.0;
		if (k == 1024)
			y = y*2.0*FIC_FD_P21023;
		else
			y = y*twopk;
		return y - 1.0;
	}
	u.i = (uint64_t)(0x3ff - k)<<52;  
	if (k < 20)
		y = (x-e+(1-u.f))*twopk;
	else
		y = (x-(e+u.f)+1)*twopk;
	return y;
}


/* ---- exp, log, log2, log10, log1p: fdlibm e_exp, e_log, s_log1p; FreeBSD e_log2 (as V8); fdlibm e_log10 ---- */
static double fic_fd_exp(double x) {
  static const double halF[2] = { 0.5, -0.5 }, o_threshold = 7.09782712893383973096e+02, u_threshold = -7.45133219101941108420e+02,
    ln2HI[2] = { 6.93147180369123816490e-01, -6.93147180369123816490e-01 }, ln2LO[2] = { 1.90821492927058770002e-10, -1.90821492927058770002e-10 },
    invln2 = 1.44269504088896338700e+00, P1 = 1.66666666666666019037e-01, P2 = -2.77777777770155933842e-03,
    P3 = 6.61375632143793436117e-05, P4 = -1.65339022054652515390e-06, P5 = 4.13813679705723846039e-08,
    huge = 1.0e+300, twom1000 = 9.33263618503218878990e-302;
  double y, hi = 0.0, lo = 0.0, c, t, twopk; int32_t k = 0, xsb; uint32_t hx;
  GET_HIGH_WORD(hx, x); xsb = (hx >> 31) & 1; hx &= 0x7fffffff;
  if (hx >= 0x40862E42) {
    if (hx >= 0x7ff00000) { uint32_t lx; GET_LOW_WORD(lx, x); if (((hx & 0xfffff) | lx) != 0) return x + x; return (xsb == 0) ? x : 0.0; }
    if (x > o_threshold) return huge * huge;
    if (x < u_threshold) return twom1000 * twom1000;
  }
  if (hx > 0x3fd62e42) {
    if (hx < 0x3FF0A2B2) {
      if (x == 1.0) return 2.718281828459045;          /* V8: the computation below would get the last bit of E wrong */
      hi = x - ln2HI[xsb]; lo = ln2LO[xsb]; k = 1 - xsb - xsb;
    }
    else { k = (int)(invln2 * x + halF[xsb]); t = k; hi = x - t * ln2HI[0]; lo = t * ln2LO[0]; }
    x = hi - lo;
  } else if (hx < 0x3e300000) { if (huge + x > 1.0) return 1.0 + x; }
  else k = 0;
  t = x * x;
  if (k >= -1021) twopk = fic_fd_from(0x3ff00000u + ((uint32_t)k << 20), 0);
  else twopk = fic_fd_from(0x3ff00000u + ((uint32_t)(k + 1000) << 20), 0);
  c = x - t * (P1 + t * (P2 + t * (P3 + t * (P4 + t * P5))));
  if (k == 0) return 1.0 - ((x * c) / (c - 2.0) - x);
  y = 1.0 - ((lo - (x * c) / (2.0 - c)) - hi);
  if (k >= -1021) { if (k == 1024) return y * 2.0 * 8.98846567431158e307; return y * twopk; }
  return y * twopk * twom1000;
}

static const double fic_fd_Lg1 = 6.666666666666735130e-01, fic_fd_Lg2 = 3.999999999940941908e-01, fic_fd_Lg3 = 2.857142874366239149e-01,
  fic_fd_Lg4 = 2.222219843214978396e-01, fic_fd_Lg5 = 1.818357216161805012e-01, fic_fd_Lg6 = 1.531383769920937332e-01,
  fic_fd_Lg7 = 1.479819860511658591e-01, fic_fd_ln2_hi = 6.93147180369123816490e-01, fic_fd_ln2_lo = 1.90821492927058770002e-10;

static double fic_fd_log(double x) {
  static const double two54 = 1.80143985094819840000e+16;
  double hfsq, f, s, z, R, w, t1, t2, dk; int32_t k, hx, i, j; uint32_t lx;
  EXTRACT_WORDS(hx, lx, x);
  k = 0;
  if (hx < 0x00100000) {
    if (((hx & 0x7fffffff) | lx) == 0) return -two54 / 0.0;
    if (hx < 0) return (x - x) / 0.0;
    k -= 54; x *= two54; GET_HIGH_WORD(hx, x);
  }
  if (hx >= 0x7ff00000) return x + x;
  k += (hx >> 20) - 1023;
  hx &= 0x000fffff;
  i = (hx + 0x95f64) & 0x100000;
  SET_HIGH_WORD(x, hx | (i ^ 0x3ff00000));
  k += (i >> 20);
  f = x - 1.0;
  if ((0x000fffff & (2 + hx)) < 3) {
    if (f == 0.0) { if (k == 0) return 0.0; dk = (double)k; return dk * fic_fd_ln2_hi + dk * fic_fd_ln2_lo; }
    R = f * f * (0.5 - 0.33333333333333333 * f);
    if (k == 0) return f - R;
    dk = (double)k; return dk * fic_fd_ln2_hi - ((R - dk * fic_fd_ln2_lo) - f);
  }
  s = f / (2.0 + f);
  dk = (double)k;
  z = s * s;
  i = hx - 0x6147a;
  w = z * z;
  j = 0x6b851 - hx;
  t1 = w * (fic_fd_Lg2 + w * (fic_fd_Lg4 + w * fic_fd_Lg6));
  t2 = z * (fic_fd_Lg1 + w * (fic_fd_Lg3 + w * (fic_fd_Lg5 + w * fic_fd_Lg7)));
  i |= j;
  R = t2 + t1;
  if (i > 0) {
    hfsq = 0.5 * f * f;
    if (k == 0) return f - (hfsq - s * (hfsq + R));
    return dk * fic_fd_ln2_hi - ((hfsq - (s * (hfsq + R) + dk * fic_fd_ln2_lo)) - f);
  }
  if (k == 0) return f - s * (f - R);
  return dk * fic_fd_ln2_hi - ((s * (f - R) - dk * fic_fd_ln2_lo) - f);
}

static double fic_fd_k_log1p(double f) {
  double hfsq, s, z, R, w, t1, t2;
  s = f / (2.0 + f);
  z = s * s;
  w = z * z;
  t1 = w * (fic_fd_Lg2 + w * (fic_fd_Lg4 + w * fic_fd_Lg6));
  t2 = z * (fic_fd_Lg1 + w * (fic_fd_Lg3 + w * (fic_fd_Lg5 + w * fic_fd_Lg7)));
  R = t2 + t1;
  hfsq = 0.5 * f * f;
  return s * (hfsq + R);
}

static double fic_fd_log2(double x) {
  static const double two54 = 1.80143985094819840000e+16, ivln2hi = 1.44269504072144627571e+00, ivln2lo = 1.67517131648865118353e-10;
  double f, hfsq, hi, lo, r, val_hi, val_lo, w, y; int32_t i, k, hx; uint32_t lx;
  EXTRACT_WORDS(hx, lx, x);
  k = 0;
  if (hx < 0x00100000) {
    if (((hx & 0x7fffffff) | lx) == 0) return -two54 / 0.0;
    if (hx < 0) return (x - x) / 0.0;
    k -= 54; x *= two54; GET_HIGH_WORD(hx, x);
  }
  if (hx >= 0x7ff00000) return x + x;
  if (hx == 0x3ff00000 && lx == 0) return 0.0;
  k += (hx >> 20) - 1023;
  hx &= 0x000fffff;
  i = (hx + 0x95f64) & 0x100000;
  SET_HIGH_WORD(x, hx | (i ^ 0x3ff00000));
  k += (i >> 20);
  y = (double)k;
  f = x - 1.0;
  hfsq = 0.5 * f * f;
  r = fic_fd_k_log1p(f);
  hi = f - hfsq;
  SET_LOW_WORD(hi, 0);
  lo = (f - hi) - hfsq + r;
  val_hi = hi * ivln2hi;
  val_lo = (lo + hi) * ivln2lo + lo * ivln2hi;
  w = y + val_hi;
  val_lo += (y - w) + val_hi;
  val_hi = w;
  return val_lo + val_hi;
}

static double fic_fd_log10(double x) {
  static const double two54 = 1.80143985094819840000e+16, ivln10 = 4.34294481903251816668e-01,
    log10_2hi = 3.01029995663611771306e-01, log10_2lo = 3.69423907715893078616e-13;
  double y, z; int32_t i, k, hx; uint32_t lx;
  EXTRACT_WORDS(hx, lx, x);
  k = 0;
  if (hx < 0x00100000) {
    if (((hx & 0x7fffffff) | lx) == 0) return -two54 / 0.0;
    if (hx < 0) return (x - x) / 0.0;
    k -= 54; x *= two54; GET_HIGH_WORD(hx, x);
  }
  if (hx >= 0x7ff00000) return x + x;
  if (hx == 0x3ff00000 && lx == 0) return 0.0;
  k += (hx >> 20) - 1023;
  i = (int32_t)(((uint32_t)k & 0x80000000u) >> 31);
  hx = (hx & 0x000fffff) | ((0x3ff - i) << 20);
  y = (double)(k + i);
  SET_HIGH_WORD(x, hx);
  z = y * log10_2lo + ivln10 * fic_fd_log(x);
  return z + y * log10_2hi;
}

static double fic_fd_log1p(double x) {
  static const double two54 = 1.80143985094819840000e+16;
  double hfsq, f = 0, c = 0, s, z, R, u; int32_t k, hx, hu = 0, ax;
  GET_HIGH_WORD(hx, x); ax = hx & 0x7fffffff;
  k = 1;
  if (hx < 0x3FDA827A) {
    if (ax >= 0x3ff00000) {
      if (x == -1.0) return -two54 / 0.0;
      return (x - x) / (x - x);
    }
    if (ax < 0x3e200000) {
      if (two54 + x > 0.0 && ax < 0x3c900000) return x;
      return x - x * x * 0.5;
    }
    if (hx > 0 || hx <= (int32_t)0xbfd2bec3) { k = 0; f = x; hu = 1; }
  }
  if (hx >= 0x7ff00000) return x + x;
  if (k != 0) {
    if (hx < 0x43400000) {
      u = 1.0 + x; GET_HIGH_WORD(hu, u);
      k = (hu >> 20) - 1023;
      c = (k > 0) ? 1.0 - (u - x) : x - (u - 1.0);
      c /= u;
    } else {
      u = x; GET_HIGH_WORD(hu, u);
      k = (hu >> 20) - 1023;
      c = 0;
    }
    hu &= 0x000fffff;
    if (hu < 0x6a09e) { SET_HIGH_WORD(u, hu | 0x3ff00000); }
    else { k += 1; SET_HIGH_WORD(u, hu | 0x3fe00000); hu = (0x00100000 - hu) >> 2; }
    f = u - 1.0;
  }
  hfsq = 0.5 * f * f;
  if (hu == 0) {
    if (f == 0.0) { if (k == 0) return 0.0; c += k * fic_fd_ln2_lo; return k * fic_fd_ln2_hi + c; }
    R = hfsq * (1.0 - 0.66666666666666666 * f);
    if (k == 0) return f - R;
    return k * fic_fd_ln2_hi - ((R - (k * fic_fd_ln2_lo + c)) - f);
  }
  s = f / (2.0 + f);
  z = s * s;
  R = z * (fic_fd_Lg1 + z * (fic_fd_Lg2 + z * (fic_fd_Lg3 + z * (fic_fd_Lg4 + z * (fic_fd_Lg5 + z * (fic_fd_Lg6 + z * fic_fd_Lg7))))));
  if (k == 0) return f - (hfsq - s * (hfsq + R));
  return k * fic_fd_ln2_hi - ((hfsq - (s * (hfsq + R) + (k * fic_fd_ln2_lo + c))) - f);
}



static const uint32_t
cb_B1 = 715094163, 
cb_B2 = 696219795; 
static const double
cb_P0 =  1.87595182427177009643,  
cb_P1 = -1.88497979543377169875,  
cb_P2 =  1.621429720105354466140, 
cb_P3 = -0.758397934778766047437, 
cb_P4 =  0.145996192886612446982; 
static double fic_fd_cbrt(double x)
{
	union {double f; uint64_t i;} u = {x};
	double r,s,t,w;
	uint32_t hx = u.i>>32 & 0x7fffffff;
	if (hx >= 0x7ff00000)  
		return x+x;
	if (hx < 0x00100000) { 
		u.f = x*FIC_FD_P254;
		hx = u.i>>32 & 0x7fffffff;
		if (hx == 0)
			return x;  
		hx = hx/3 + cb_B2;
	} else
		hx = hx/3 + cb_B1;
	u.i &= 1ULL<<63;
	u.i |= (uint64_t)hx << 32;
	t = u.f;
	r = (t*t)*(t/x);
	t = t*((cb_P0+r*(cb_P1+r*cb_P2))+((r*r)*r)*(cb_P3+r*cb_P4));
	u.f = t;
	u.i = (u.i + 0x80000000) & 0xffffffffc0000000ULL;
	t = u.f;
	s = t*t;         
	r = x/s;         
	w = t+t;         
	r = (r-t)/(w+r); 
	t = t+t*r;       
	return t;
}


/* ---- atan, atan2, asin, acos: fdlibm ---- */
static double fic_fd_atan(double x) {
  static const double atanhi[] = { 4.63647609000806093515e-01, 7.85398163397448278999e-01, 9.82793723247329054082e-01, 1.57079632679489655800e+00 };
  static const double atanlo[] = { 2.26987774529616870924e-17, 3.06161699786838301793e-17, 1.39033110312309984516e-17, 6.12323399573676603587e-17 };
  static const double aT[] = { 3.33333333333329318027e-01, -1.99999999998764832476e-01, 1.42857142725034663711e-01, -1.11111104054623557880e-01,
    9.09088713343650656196e-02, -7.69187620504482999495e-02, 6.66107313738753120669e-02, -5.83357013379057348645e-02,
    4.97687799461593236017e-02, -3.65315727442169155270e-02, 1.62858201153657823623e-02 };
  double w, s1, s2, z; int32_t ix, hx, id;
  GET_HIGH_WORD(hx, x); ix = hx & 0x7fffffff;
  if (ix >= 0x44100000) {
    uint32_t low; GET_LOW_WORD(low, x);
    if (ix > 0x7ff00000 || (ix == 0x7ff00000 && low != 0)) return x + x;
    if (hx > 0) return atanhi[3] + atanlo[3];
    return -atanhi[3] - atanlo[3];
  }
  if (ix < 0x3fdc0000) {
    if (ix < 0x3e200000) { if (1e300 + x > 1.0) return x; }
    id = -1;
  } else {
    x = fabs(x);
    if (ix < 0x3ff30000) {
      if (ix < 0x3fe60000) { id = 0; x = (2.0 * x - 1.0) / (2.0 + x); }
      else { id = 1; x = (x - 1.0) / (x + 1.0); }
    } else {
      if (ix < 0x40038000) { id = 2; x = (x - 1.5) / (1.0 + 1.5 * x); }
      else { id = 3; x = -1.0 / x; }
    }
  }
  z = x * x; w = z * z;
  s1 = z * (aT[0] + w * (aT[2] + w * (aT[4] + w * (aT[6] + w * (aT[8] + w * aT[10])))));
  s2 = w * (aT[1] + w * (aT[3] + w * (aT[5] + w * (aT[7] + w * aT[9]))));
  if (id < 0) return x - x * (s1 + s2);
  z = atanhi[id] - ((x * (s1 + s2) - atanlo[id]) - x);
  return (hx < 0) ? -z : z;
}

static double fic_fd_atan2(double y, double x) {
  static const double tiny = 1.0e-300, pi_o_4 = 7.8539816339744827900E-01, pi_o_2 = 1.5707963267948965580E+00,
    pi = 3.1415926535897931160E+00, pi_lo = 1.2246467991473531772E-16;
  double z; int32_t k, m, hx, hy, ix, iy; uint32_t lx, ly;
  EXTRACT_WORDS(hx, lx, x); ix = hx & 0x7fffffff;
  EXTRACT_WORDS(hy, ly, y); iy = hy & 0x7fffffff;
  if (((uint32_t)ix | ((lx | -lx) >> 31)) > 0x7ff00000 || ((uint32_t)iy | ((ly | -ly) >> 31)) > 0x7ff00000) return x + y;
  if ((((uint32_t)hx - 0x3ff00000u) | lx) == 0) return fic_fd_atan(y);
  m = ((hy >> 31) & 1) | ((hx >> 30) & 2);
  if ((iy | ly) == 0) {
    switch (m) { case 0: case 1: return y; case 2: return pi + tiny; default: return -pi - tiny; }
  }
  if ((ix | lx) == 0) return (hy < 0) ? -pi_o_2 - tiny : pi_o_2 + tiny;
  if (ix == 0x7ff00000) {
    if (iy == 0x7ff00000) {
      switch (m) { case 0: return pi_o_4 + tiny; case 1: return -pi_o_4 - tiny; case 2: return 3.0 * pi_o_4 + tiny; default: return -3.0 * pi_o_4 - tiny; }
    } else {
      switch (m) { case 0: return 0.0; case 1: return -0.0; case 2: return pi + tiny; default: return -pi - tiny; }
    }
  }
  if (iy == 0x7ff00000) return (hy < 0) ? -pi_o_2 - tiny : pi_o_2 + tiny;
  k = (iy - ix) >> 20;
  if (k > 60) { z = pi_o_2 + 0.5 * pi_lo; m &= 1; }
  else if (hx < 0 && k < -60) z = 0.0;
  else z = fic_fd_atan(fabs(y / x));
  switch (m) {
    case 0: return z;
    case 1: return -z;
    case 2: return pi - (z - pi_lo);
    default: return (z - pi_lo) - pi;
  }
}

static const double fic_fd_pio2_hi = 1.57079632679489655800e+00, fic_fd_pio2_lo = 6.12323399573676603587e-17,
  fic_fd_pS0 = 1.66666666666666657415e-01, fic_fd_pS1 = -3.25565818622400915405e-01, fic_fd_pS2 = 2.01212532134862925881e-01,
  fic_fd_pS3 = -4.00555345006794114027e-02, fic_fd_pS4 = 7.91534994289814532176e-04, fic_fd_pS5 = 3.47933107596021167570e-05,
  fic_fd_qS1 = -2.40339491173441421878e+00, fic_fd_qS2 = 2.02094576023350569471e+00, fic_fd_qS3 = -6.88283971605453293030e-01,
  fic_fd_qS4 = 7.70381505559019352791e-02;

static double fic_fd_asin(double x) {
  static const double pio4_hi = 7.85398163397448278999e-01;
  double t = 0, w, p, q, c, r, s; int32_t hx, ix;
  GET_HIGH_WORD(hx, x); ix = hx & 0x7fffffff;
  if (ix >= 0x3ff00000) {
    uint32_t lx; GET_LOW_WORD(lx, x);
    if (((ix - 0x3ff00000) | lx) == 0) return x * fic_fd_pio2_hi + x * fic_fd_pio2_lo;
    return (x - x) / (x - x);
  } else if (ix < 0x3fe00000) {
    if (ix < 0x3e400000) { if (1e300 + x > 1.0) return x; }
    else t = x * x;
    p = t * (fic_fd_pS0 + t * (fic_fd_pS1 + t * (fic_fd_pS2 + t * (fic_fd_pS3 + t * (fic_fd_pS4 + t * fic_fd_pS5)))));
    q = 1.0 + t * (fic_fd_qS1 + t * (fic_fd_qS2 + t * (fic_fd_qS3 + t * fic_fd_qS4)));
    w = p / q;
    return x + x * w;
  }
  w = 1.0 - fabs(x);
  t = w * 0.5;
  p = t * (fic_fd_pS0 + t * (fic_fd_pS1 + t * (fic_fd_pS2 + t * (fic_fd_pS3 + t * (fic_fd_pS4 + t * fic_fd_pS5)))));
  q = 1.0 + t * (fic_fd_qS1 + t * (fic_fd_qS2 + t * (fic_fd_qS3 + t * fic_fd_qS4)));
  s = sqrt(t);
  if (ix >= 0x3FEF3333) {
    w = p / q;
    t = fic_fd_pio2_hi - (2.0 * (s + s * w) - fic_fd_pio2_lo);
  } else {
    w = s; SET_LOW_WORD(w, 0);
    c = (t - w * w) / (s + w);
    r = p / q;
    p = 2.0 * s * r - (fic_fd_pio2_lo - 2.0 * c);
    q = pio4_hi - 2.0 * w;
    t = pio4_hi - (p - q);
  }
  return (hx > 0) ? t : -t;
}

static double fic_fd_acos(double x) {
  static const double pi = 3.14159265358979311600e+00;
  double z, p, q, r, w, s, c, df; int32_t hx, ix;
  GET_HIGH_WORD(hx, x); ix = hx & 0x7fffffff;
  if (ix >= 0x3ff00000) {
    uint32_t lx; GET_LOW_WORD(lx, x);
    if (((ix - 0x3ff00000) | lx) == 0) { if (hx > 0) return 0.0; return pi + 2.0 * fic_fd_pio2_lo; }
    return (x - x) / (x - x);
  }
  if (ix < 0x3fe00000) {
    if (ix <= 0x3c600000) return fic_fd_pio2_hi + fic_fd_pio2_lo;
    z = x * x;
    p = z * (fic_fd_pS0 + z * (fic_fd_pS1 + z * (fic_fd_pS2 + z * (fic_fd_pS3 + z * (fic_fd_pS4 + z * fic_fd_pS5)))));
    q = 1.0 + z * (fic_fd_qS1 + z * (fic_fd_qS2 + z * (fic_fd_qS3 + z * fic_fd_qS4)));
    r = p / q;
    return fic_fd_pio2_hi - (x - (fic_fd_pio2_lo - x * r));
  } else if (hx < 0) {
    z = (1.0 + x) * 0.5;
    p = z * (fic_fd_pS0 + z * (fic_fd_pS1 + z * (fic_fd_pS2 + z * (fic_fd_pS3 + z * (fic_fd_pS4 + z * fic_fd_pS5)))));
    q = 1.0 + z * (fic_fd_qS1 + z * (fic_fd_qS2 + z * (fic_fd_qS3 + z * fic_fd_qS4)));
    s = sqrt(z);
    r = p / q;
    w = r * s - fic_fd_pio2_lo;
    return pi - 2.0 * (s + w);
  } else {
    z = (1.0 - x) * 0.5;
    s = sqrt(z);
    df = s; SET_LOW_WORD(df, 0);
    c = (z - df * df) / (s + df);
    p = z * (fic_fd_pS0 + z * (fic_fd_pS1 + z * (fic_fd_pS2 + z * (fic_fd_pS3 + z * (fic_fd_pS4 + z * fic_fd_pS5)))));
    q = 1.0 + z * (fic_fd_qS1 + z * (fic_fd_qS2 + z * (fic_fd_qS3 + z * fic_fd_qS4)));
    r = p / q;
    w = r * s + c;
    return 2.0 * (df + w);
  }
}

/* ---- sinh, cosh, tanh, asinh, acosh, atanh (V8's versions of the fdlibm functions) ---- */
static double fic_fd_sinh(double x) {
  double h = (x < 0) ? -0.5 : 0.5, ax = fabs(x);
  if (ax < 22) {
    double t;
    if (ax < 3.725290298461914e-9) return x;
    t = fic_fd_expm1(ax);
    if (ax < 1) return h * (2.0 * t - t * t / (t + 1.0));
    return h * (t + t / (t + 1.0));
  }
  if (ax < 709.7822265625) return h * fic_fd_exp(ax);
  if (ax <= 710.4758600739439) { double w = fic_fd_exp(0.5 * ax); double t = h * w; return t * w; }
  return x * 1.0e307;
}

static double fic_fd_cosh(double x) {
  int32_t ix;
  GET_HIGH_WORD(ix, x); ix &= 0x7fffffff;
  if (ix < 0x3fd62e43) {
    double t = fic_fd_expm1(fabs(x)); double w = 1.0 + t;
    if (ix < 0x3c800000) return w;
    return 1.0 + (t * t) / (w + w);
  }
  if (ix < 0x40360000) { double t = fic_fd_exp(fabs(x)); return 0.5 * t + 0.5 / t; }
  if (ix < 0x40862e42) return 0.5 * fic_fd_exp(fabs(x));
  if (fabs(x) <= 710.4758600739439) { double w = fic_fd_exp(0.5 * fabs(x)); double t = 0.5 * w; return t * w; }
  if (ix >= 0x7ff00000) return x * x;
  return 1.0e300 * 1.0e300;
}

static double fic_fd_tanh(double x) {
  double t, z; int32_t jx, ix;
  GET_HIGH_WORD(jx, x); ix = jx & 0x7fffffff;
  if (ix >= 0x7ff00000) { if (jx >= 0) return 1.0 / x + 1.0; return 1.0 / x - 1.0; }
  if (ix < 0x40360000) {
    if (ix < 0x3e300000) { if (1.0e300 + x > 1.0) return x; }
    if (ix >= 0x3ff00000) { t = fic_fd_expm1(2.0 * fabs(x)); z = 1.0 - 2.0 / (t + 2.0); }
    else { t = fic_fd_expm1(-2.0 * fabs(x)); z = -t / (t + 2.0); }
  } else z = 1.0 - 1.0e-300;
  return (jx >= 0) ? z : -z;
}

static double fic_fd_asinh(double x) {
  static const double ln2 = 6.93147180559945286227e-01;
  double t, w; int32_t hx, ix;
  GET_HIGH_WORD(hx, x); ix = hx & 0x7fffffff;
  if (ix >= 0x7ff00000) return x + x;
  if (ix < 0x3e300000) { if (1.0e300 + x > 1.0) return x; }
  if (ix > 0x41b00000) w = fic_fd_log(fabs(x)) + ln2;
  else if (ix > 0x40000000) { t = fabs(x); w = fic_fd_log(2.0 * t + 1.0 / (sqrt(x * x + 1.0) + t)); }
  else { t = x * x; w = fic_fd_log1p(fabs(x) + t / (1.0 + sqrt(1.0 + t))); }
  return (hx > 0) ? w : -w;
}

static double fic_fd_acosh(double x) {
  static const double ln2 = 6.93147180559945286227e-01;
  double t; int32_t hx; uint32_t lx;
  EXTRACT_WORDS(hx, lx, x);
  if (hx < 0x3ff00000) return (x - x) / (x - x);
  if (hx >= 0x41b00000) { if (hx >= 0x7ff00000) return x + x; return fic_fd_log(x) + ln2; }
  if (((hx - 0x3ff00000) | lx) == 0) return 0.0;
  if (hx > 0x40000000) { t = x * x; return fic_fd_log(2.0 * x - 1.0 / (x + sqrt(t - 1.0))); }
  t = x - 1.0;
  return fic_fd_log1p(t + sqrt(2.0 * t + t * t));
}

static double fic_fd_atanh(double x) {
  double t; int32_t hx, ix; uint32_t lx;
  EXTRACT_WORDS(hx, lx, x); ix = hx & 0x7fffffff;
  if (((uint32_t)ix | ((lx | -lx) >> 31)) > 0x3ff00000) return (x - x) / (x - x);
  if (ix == 0x3ff00000) return x / 0.0;
  if (ix < 0x3e300000 && (1.0e300 + x) > 0.0) return x;
  SET_HIGH_WORD(x, ix);
  if (ix < 0x3fe00000) { t = x + x; t = 0.5 * fic_fd_log1p(t + t * x / (1.0 - x)); }
  else t = 0.5 * fic_fd_log1p((x + x) / (1.0 - x));
  return (hx >= 0) ? t : -t;
}

/* ---- pow: fdlibm e_pow.c with V8's special cases (ieee754::legacy::pow) ---- */
static double fic_fd_pow(double x, double y) {
  static const double bp[] = { 1.0, 1.5 }, dp_h[] = { 0.0, 5.84962487220764160156e-01 }, dp_l[] = { 0.0, 1.35003920212974897128e-08 },
    two53 = 9007199254740992.0, huge = 1.0e300, tiny = 1.0e-300,
    L1 = 5.99999999999994648725e-01, L2 = 4.28571428578550184252e-01, L3 = 3.33333329818377432918e-01,
    L4 = 2.72728123808534006489e-01, L5 = 2.30660745775561754067e-01, L6 = 2.06975017800338417784e-01,
    P1 = 1.66666666666666019037e-01, P2 = -2.77777777770155933842e-03, P3 = 6.61375632143793436117e-05,
    P4 = -1.65339022054652515390e-06, P5 = 4.13813679705723846039e-08,
    lg2 = 6.93147180559945286227e-01, lg2_h = 6.93147182464599609375e-01, lg2_l = -1.90465429995776804525e-09,
    ovt = 8.0085662595372944372e-17, cp = 9.61796693925975554329e-01, cp_h = 9.61796700954437255859e-01, cp_l = -7.02846165095275826516e-09,
    ivln2 = 1.44269504088896338700e+00, ivln2_h = 1.44269502162933349609e+00, ivln2_l = 1.92596299112661746887e-08;
  double z, ax, z_h, z_l, p_h, p_l, y1, t1, t2, r, s, t, u, v, w; int32_t i, j, k, yisint, n, hx, hy, ix, iy; uint32_t lx, ly;
  if (y == 0.0) return 1.0;
  if (y != y || ((x == 1 || x == -1) && isinf(y))) return NAN;
  EXTRACT_WORDS(hx, lx, x); EXTRACT_WORDS(hy, ly, y);
  ix = hx & 0x7fffffff; iy = hy & 0x7fffffff;
  if (ix > 0x7ff00000 || (ix == 0x7ff00000 && lx != 0) || iy > 0x7ff00000 || (iy == 0x7ff00000 && ly != 0)) return x + y;
  yisint = 0;
  if (hx < 0) {
    if (iy >= 0x43400000) yisint = 2;
    else if (iy >= 0x3ff00000) {
      k = (iy >> 20) - 0x3ff;
      if (k > 20) { j = (int32_t)(ly >> (52 - k)); if ((uint32_t)(j << (52 - k)) == ly) yisint = 2 - (j & 1); }
      else if (ly == 0) { j = iy >> (20 - k); if ((j << (20 - k)) == iy) yisint = 2 - (j & 1); }
    }
  }
  if (ly == 0) {
    if (iy == 0x7ff00000) {
      if (((ix - 0x3ff00000) | lx) == 0) return y - y;
      else if (ix >= 0x3ff00000) return (hy >= 0) ? y : 0.0;
      else return (hy < 0) ? -y : 0.0;
    }
    if (iy == 0x3ff00000) { if (hy < 0) return 1.0 / x; else return x; }
    if (hy == 0x40000000) return x * x;
    if (hy == 0x3fe00000) { if (hx >= 0) return sqrt(x); }
  }
  ax = fabs(x);
  if (lx == 0) {
    if (ix == 0x7ff00000 || ix == 0 || ix == 0x3ff00000) {
      z = ax;
      if (hy < 0) z = 1.0 / z;
      if (hx < 0) {
        if (((ix - 0x3ff00000) | yisint) == 0) z = (z - z) / (z - z);
        else if (yisint == 1) z = -z;
      }
      return z;
    }
  }
  n = (int32_t)(((uint32_t)hx >> 31) - 1);
  if ((n | yisint) == 0) return (x - x) / (x - x);
  s = 1.0;
  if ((n | (yisint - 1)) == 0) s = -1.0;
  if (iy > 0x41e00000) {
    if (iy > 0x43f00000) {
      if (ix <= 0x3fefffff) return (hy < 0) ? huge * huge : tiny * tiny;
      if (ix >= 0x3ff00000) return (hy > 0) ? huge * huge : tiny * tiny;
    }
    if (ix < 0x3fefffff) return (hy < 0) ? s * huge * huge : s * tiny * tiny;
    if (ix > 0x3ff00000) return (hy > 0) ? s * huge * huge : s * tiny * tiny;
    t = ax - 1.0;
    w = (t * t) * (0.5 - t * (0.3333333333333333333333 - t * 0.25));
    u = ivln2_h * t;
    v = t * ivln2_l - w * ivln2;
    t1 = u + v;
    SET_LOW_WORD(t1, 0);
    t2 = v - (t1 - u);
  } else {
    double ss, s2, s_h, s_l, t_h, t_l;
    n = 0;
    if (ix < 0x00100000) { ax *= two53; n -= 53; GET_HIGH_WORD(ix, ax); }
    n += ((ix) >> 20) - 0x3ff;
    j = ix & 0x000fffff;
    ix = j | 0x3ff00000;
    if (j <= 0x3988E) k = 0;
    else if (j < 0xBB67A) k = 1;
    else { k = 0; n += 1; ix -= 0x00100000; }
    SET_HIGH_WORD(ax, ix);
    u = ax - bp[k];
    v = 1.0 / (ax + bp[k]);
    ss = u * v;
    s_h = ss; SET_LOW_WORD(s_h, 0);
    t_h = 0.0; SET_HIGH_WORD(t_h, ((ix >> 1) | 0x20000000) + 0x00080000 + (k << 18));
    t_l = ax - (t_h - bp[k]);
    s_l = v * ((u - s_h * t_h) - s_h * t_l);
    s2 = ss * ss;
    r = s2 * s2 * (L1 + s2 * (L2 + s2 * (L3 + s2 * (L4 + s2 * (L5 + s2 * L6)))));
    r += s_l * (s_h + ss);
    s2 = s_h * s_h;
    t_h = 3.0 + s2 + r; SET_LOW_WORD(t_h, 0);
    t_l = r - ((t_h - 3.0) - s2);
    u = s_h * t_h;
    v = s_l * t_h + t_l * ss;
    p_h = u + v; SET_LOW_WORD(p_h, 0);
    p_l = v - (p_h - u);
    z_h = cp_h * p_h;
    z_l = cp_l * p_h + p_l * cp + dp_l[k];
    t = (double)n;
    t1 = (((z_h + z_l) + dp_h[k]) + t); SET_LOW_WORD(t1, 0);
    t2 = z_l - (((t1 - t) - dp_h[k]) - z_h);
  }
  y1 = y; SET_LOW_WORD(y1, 0);
  p_l = (y - y1) * t1 + y * t2;
  p_h = y1 * t1;
  z = p_l + p_h;
  EXTRACT_WORDS(j, i, z);
  if (j >= 0x40900000) {
    if (((j - 0x40900000) | i) != 0) return s * huge * huge;
    if (p_l + ovt > z - p_h) return s * huge * huge;
  } else if ((j & 0x7fffffff) >= 0x4090cc00) {
    if ((((uint32_t)j - 0xc090cc00u) | i) != 0) return s * tiny * tiny;
    if (p_l <= z - p_h) return s * tiny * tiny;
  }
  i = j & 0x7fffffff;
  k = (i >> 20) - 0x3ff;
  n = 0;
  if (i > 0x3fe00000) {
    n = j + (0x00100000 >> (k + 1));
    k = ((n & 0x7fffffff) >> 20) - 0x3ff;
    t = 0.0; SET_HIGH_WORD(t, n & ~(0x000fffff >> k));
    n = ((n & 0x000fffff) | 0x00100000) >> (20 - k);
    if (j < 0) n = -n;
    p_h -= t;
  }
  t = p_l + p_h; SET_LOW_WORD(t, 0);
  u = t * lg2_h;
  v = (p_l - (t - p_h)) * lg2 + t * lg2_l;
  z = u + v;
  w = v - (z - u);
  t = z * z;
  t1 = z - t * (P1 + t * (P2 + t * (P3 + t * (P4 + t * P5))));
  r = (z * t1) / ((t1 - 2.0) - (w + z * w));      /* V8's form (not fdlibm's (z*t1)/(t1-2) - (w+z*w)) */
  z = 1.0 - (r - z);
  GET_HIGH_WORD(j, z);
  j = (int32_t)((uint32_t)j + ((uint32_t)n << 20));
  if ((j >> 20) <= 0) z = fic_fd_scalbn(z, n);
  else SET_HIGH_WORD(z, j);
  return s * z;
}

/* logBase: log y / log x, with the exact log2 and log10 for the bases 2 and 10 (decision L5: logBase 10 1000 is 3) */
static double fic_fd_logbase(double base, double x) {
  if (base == 10.0) return fic_fd_log10(x);
  if (base == 2.0) return fic_fd_log2(x);
  return fic_fd_log(x) / fic_fd_log(base);
}
