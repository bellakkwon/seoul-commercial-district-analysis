"""원천 파일(data/raw)을 SQL이 읽는 이름·인코딩(UTF-8)으로 data/processed에 준비한다.

필요한 원천 파일 (data/README.md 참고)
- 서울시_상권분석서비스_추정매출-상권__2024년.zip / __2025년.zip
- 서울시_상권분석서비스_점포-상권__2024년.zip / __2025년.zip
- 서울시_상권분석서비스_상권변화지표-상권_.csv
"""
import zipfile, glob, os, io
RAW, OUT = 'data/raw', 'data/processed'
os.makedirs(OUT, exist_ok=True)

def to_utf8(raw_bytes):
    for enc in ('utf-8', 'cp949'):
        try:
            return raw_bytes.decode(enc)
        except UnicodeDecodeError:
            pass
    raise ValueError('알 수 없는 인코딩')

targets = {
    '추정매출-상권__2024년': 'sales_2024.csv', '추정매출-상권__2025년': 'sales_2025.csv',
    '점포-상권__2024년': 'store_2024.csv', '점포-상권__2025년': 'store_2025.csv',
}
for key, out in targets.items():
    z = glob.glob(os.path.join(RAW, f'*{key}*.zip'))
    assert z, f'원천 파일 없음: {key}'
    with zipfile.ZipFile(z[0]) as zf:
        name = [n for n in zf.namelist() if n.lower().endswith('.csv')][0]
        text = to_utf8(zf.read(name))
    open(os.path.join(OUT, out), 'w', encoding='utf-8').write(text)
    print('ok', out)

chg = glob.glob(os.path.join(RAW, '*상권변화지표*.csv'))[0]
open(os.path.join(OUT, 'chg.csv'), 'w', encoding='utf-8').write(to_utf8(open(chg, 'rb').read()))
print('ok chg.csv')
