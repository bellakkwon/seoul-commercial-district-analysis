"""소진공 카페(I21201) 위치를 서울시 상권 영역 SHP에 공간 결합한다 (GeoPandas, EPSG:5181).

출력: data/processed/cafe_trdar_pairs.csv (카페 × 상권), data/processed/trdar_area.csv (상권 면적)
→ sql/seoul_cafe_trdar_analysis.sql 10번 섹션의 입력
"""
import glob
import pandas as pd, geopandas as gpd
from shapely.validation import make_valid
cols=['상가업소번호','상호명','상권업종소분류코드','상권업종소분류명','경도','위도']
df=pd.read_csv(glob.glob('data/raw/*상가_상권_정보_서울*.csv')[0],dtype=str,usecols=cols)
print('all',len(df), 'unique id',df['상가업소번호'].nunique())
cafe=df[df['상권업종소분류코드']=='I21201'].copy()
print('cafe',len(cafe), cafe['상권업종소분류명'].unique()[:3], 'dup ids', cafe['상가업소번호'].duplicated().sum())
cafe['x']=pd.to_numeric(cafe['경도'],errors='coerce'); cafe['y']=pd.to_numeric(cafe['위도'],errors='coerce')
print('bad coords', cafe[['x','y']].isna().any(axis=1).sum())
cafe=cafe.dropna(subset=['x','y'])
pts=gpd.GeoDataFrame(cafe[['상가업소번호']],geometry=gpd.points_from_xy(cafe.x,cafe.y),crs='EPSG:4326').to_crs('EPSG:5181')
g=gpd.read_file(glob.glob('data/raw/*영역-상권*.shp')[0])
inv=(~g.is_valid)
print('invalid geoms', inv.sum(), g.loc[inv,'TRDAR_CD_N'].tolist())
g['geometry']=g.geometry.apply(lambda s: s if s.is_valid else make_valid(s))
g['area_calc']=g.area
print('area diff (calc vs RELM_AR) median rel', ((g.area_calc-g.RELM_AR.astype(float))/g.RELM_AR.astype(float)).abs().median(), 'max', ((g.area_calc-g.RELM_AR.astype(float))/g.RELM_AR.astype(float)).abs().max())
j=gpd.sjoin(pts,g[['TRDAR_CD','geometry']],predicate='within',how='left')
mapped=j.dropna(subset=['TRDAR_CD'])
print('mapped unique cafes', mapped['상가업소번호'].nunique(), 'of', len(pts))
multi=mapped.groupby('상가업소번호')['TRDAR_CD'].nunique()
print('cafes in >1 trdar', (multi>1).sum())
pairs=mapped[['상가업소번호','TRDAR_CD']].drop_duplicates()
print('pairs',len(pairs))
pairs.rename(columns={'상가업소번호':'store_id','TRDAR_CD':'cd'}).to_csv('data/processed/cafe_trdar_pairs.csv',index=False)
out=g[['TRDAR_CD','TRDAR_CD_N','TRDAR_SE_1','RELM_AR','area_calc']].rename(columns={'TRDAR_CD':'cd','TRDAR_CD_N':'nm','TRDAR_SE_1':'tp','RELM_AR':'relm_ar_m2','area_calc':'area_calc_m2'})
out['was_invalid']=inv.values
out.to_csv('data/processed/trdar_area.csv',index=False)
# overlaps among polygons
sj=gpd.sjoin(g[['TRDAR_CD','geometry']],g[['TRDAR_CD','geometry']],predicate='overlaps')
print('overlapping polygon pairs', len(sj)//2)
