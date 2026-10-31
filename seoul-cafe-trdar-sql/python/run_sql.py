"""sql/seoul_cafe_trdar_analysis.sql을 DuckDB로 처음부터 실행하고, 각 SELECT 결과를 출력한다.
실행 위치: 저장소 최상위 폴더  →  python python/run_sql.py
"""
import duckdb, os, re
SQL = os.path.abspath('sql/seoul_cafe_trdar_analysis.sql')
os.chdir('data/processed')                     # SQL은 이 폴더의 CSV를 상대 경로로 읽음
con = duckdb.connect()
stmts = [s for s in open(SQL, encoding='utf-8').read().split(';') if re.sub(r'--[^\n]*', '', s).strip()]
for s in stmts:
    head = re.sub(r'--[^\n]*', '', s).strip()
    res = con.execute(s)
    if head.upper().startswith(('SELECT', 'WITH')):
        title = next((l.strip() for l in s.strip().splitlines() if l.strip().startswith('-- [')), '')
        cols = [d[0] for d in res.description]
        print('\n' + (title or head.splitlines()[0][:60]))
        print(' | '.join(cols))
        for row in res.fetchall()[:25]:
            print(' | '.join(str(v) for v in row))
