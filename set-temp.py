"""Set an Ember mug's target temperature over Bluetooth, bypassing the app's 50 C slider floor.

Usage: ./set-temp.sh 45        (Celsius; add F for Fahrenheit, e.g. 113F)
       ./set-temp.sh           (just read the mug)
Writes the setpoint, reads it back, and says whether the mug's firmware kept it or clamped it.
"""
import asyncio, struct, sys
from bleak import BleakScanner, BleakClient

U = lambda n: f"fc54{n:04x}-236c-4c94-8fa9-944a3e5353fa"
CUR, TGT, BATT, LIQ = U(2), U(3), U(7), U(8)
LIQUID = {1: "empty", 2: "filling", 4: "cooling", 5: "heating", 6: "holding at target"}

def c2f(c): return c * 9 / 5 + 32
def show(c): return f"{c:.1f} C / {c2f(c):.0f} F"
def temp(b): return struct.unpack("<H", bytes(b)[:2])[0] / 100

def parse(arg):
    a = arg.strip().upper()
    if a.endswith("F"): return (float(a[:-1]) - 32) * 5 / 9
    return float(a.rstrip("C"))

async def main():
    want = parse(sys.argv[1]) if len(sys.argv) > 1 else None
    print("Looking for the mug...")
    dev = await BleakScanner.find_device_by_filter(lambda d, a: (d.name or a.local_name or "").startswith("Ember"), timeout=20)
    if not dev:
        sys.exit("No Ember mug found. Put it on its coaster and try again.")
    print(f"Found {dev.name}. Connecting...")
    try:
        client = BleakClient(dev, timeout=40)
        await client.connect()
    except Exception:
        sys.exit("The mug is visible but would not connect. Another device is holding it:\n"
                 "  1. Force-quit the Ember app on your phone (and this Mac), or turn the phone's Bluetooth off.\n"
                 "  2. Hold the button on the bottom of the mug until the light flashes blue (pairing mode).\n"
                 "  3. Run this again.")
    async with client:
        before = temp(await client.read_gatt_char(TGT))
        liq = (await client.read_gatt_char(LIQ))[0]
        print(f"Coffee now: {show(temp(await client.read_gatt_char(CUR)))}, state: {LIQUID.get(liq, liq)}")
        print(f"Battery: {(await client.read_gatt_char(BATT))[0]}%")
        print(f"Target before: {show(before)}")
        if want is None: return
        async def write(c):
            await client.write_gatt_char(TGT, struct.pack("<H", round(c * 100)), response=True)
            await asyncio.sleep(1.5)
            return temp(await client.read_gatt_char(TGT))
        after = await write(want)
        if abs(after - want) >= 0.05:
            # Measured 2026-11-05 on an Ember Cup 2: a sub-120 F write is refused when the target
            # sits at the 48.9 C floor, but kept when it comes from an in-range target such as 52 C.
            print("Refused directly; stepping through 52 C first...")
            await write(52.0)
            after = await write(want)
        print(f"Asked for {show(want)}, mug now reports {show(after)}")
        if abs(after - want) < 0.05:
            print("ACCEPTED: the firmware kept the lower setpoint. Leave the app closed or it may push its own value back.")
        elif abs(after - before) < 0.05:
            print("REJECTED: the firmware ignored the write and kept the old target.")
        else:
            print(f"CLAMPED: the firmware stored {show(after)} instead. That is its floor.")

asyncio.run(main())
