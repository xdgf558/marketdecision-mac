"""Local structural guard. This is not behavioral or financial acceptance."""
from pathlib import Path
import json, re
root=Path(__file__).resolve().parents[1]
for name in ['CoreDomain','CoreCalculations','DataContracts']:
    for path in (root/'Sources'/name).glob('*.swift'):
        imports=set(re.findall(r'^import (\w+)',path.read_text(),re.M))
        assert not imports & {'SwiftUI','GRDB','DataProviders','AppComposition','Persistence'},path
pins=json.loads((root/'Package.resolved').read_text())['pins']
assert len(pins)==1 and pins[0]['state']=={'revision':'b83108d10f42680d78f23fe4d4d80fc88dab3212','version':'7.11.1'}
print('Core module boundaries and exact GRDB pin verified; no application acceptance implied.')
