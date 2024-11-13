import json
import std/strformat
import std/strutils
import std/[times, os]
import re
import sequtils
import math
import std/tables
import osproc

var DEFAULT_PROCPATH = "/proc"

var head = """{"version":1,"click_events":true,"stop_signal":0,"cont_signal":0}
["""
echo(head)
os.sleep(1*1000)

type
  Rect = object
    x, y, width, height: int

  Output = object
    name: string
    active: bool
    primary: bool
    rect: Rect

proc getWidth(): int =
  let (output, status) = execCmdEx("i3-msg -t get_outputs")
  if status != 0:
    return 0

  var outputs: seq[Output]
  try:
    outputs = to(parseJson(output), seq[Output])
  except JsonParsingError:
    return 0

  for output in outputs:
    if output.primary:
      return output.rect.width
  return outputs[0].rect.width

var module_count = 3.0

var lastIdle = 0
var lastTotal = 0

proc getCpuUsage(): int =
  let fd = open("/proc/stat", fmRead)
  defer: close(fd)
  var line = fd.readLine()
  var matches = newSeq[string](7)
  let pattern = re"(?m)^cpu +(\d+) +(\d+) +(\d+) +(\d+) +(\d+) +(\d+) +(\d+)"
  if line.find(pattern, matches) >= 0:
    let idle = parseInt(matches[3])
    let total = matches[0..6].mapIt(parseInt(it)).sum
    let idleDelta = idle - lastIdle
    let totalDelta = total - lastTotal
    lastIdle = idle
    lastTotal = total
    return int((1 - idleDelta.float / totalDelta.float) * 100)
  else:
    return 0

proc getMemUsage(): int =
  var meminfo: Table[string, int]
  for line in lines("/proc/meminfo"):
    var matches: array[2, string]
    if line.find(re"^(\w+):\s+(\d+)\s+\w+$", matches) >= 0:
      let key = matches[0]
      let val = parseInt(matches[1])
      meminfo[key] = val
  let total = meminfo["MemTotal"]
  let free = meminfo["MemFree"] + meminfo["Buffers"] + meminfo["Cached"]
  return int((total - free) / total * 100)

proc getBatteryInfo(devpath: string, useEnergyFullDesign: bool): string =
  proc getBatteryInfoReal(devpath: string, useEnergyFullDesign: bool): string =
    var
      ueventData = initTable[string, string]()
      energyFull, energyNow, powerNow: float
      matches: array[2, string]

    try:
      for line in lines(devpath / "uevent"):
        if line.match(re"POWER_SUPPLY_([^-]*)=(.*)", matches):
          let key = matches[0].toLowerAscii()
          let value = matches[1]
          ueventData[key] = value

      energyFull = parseFloat(ueventData.getOrDefault("energy_full"))
      energyNow = parseFloat(ueventData.getOrDefault("energy_now"))
      powerNow = parseFloat(ueventData.getOrDefault("power_now"))

      if ueventData.getOrDefault("charge_full").match(re"\d+"):
        let voltageNow = parseFloat(ueventData.getOrDefault("voltage_now"))
        energyFull = parseFloat(ueventData.getOrDefault("charge_full")) *
            voltageNow / 1_000_000
        energyNow = parseFloat(ueventData.getOrDefault("charge_now")) *
            voltageNow / 1_000_000
        if ueventData.getOrDefault("current_now").len > 0:
          powerNow = parseFloat(ueventData.getOrDefault("current_now")) *
              voltageNow / 1_000_000

      let status = ueventData.getOrDefault("status")
      var energyFullDesign = energyFull
      if useEnergyFullDesign:
        energyFullDesign = parseFloat(ueventData.getOrDefault("energy_full_design"))

      let capacity = min(int(energyNow / energyFullDesign * 100 + 0.5), 100)
      var consumption, remTime: float
      var flag: string

      if powerNow != 0:
        consumption = powerNow / 1_000_000
        flag = "↑"
        if status == "Charging":
          remTime = (energyFull - energyNow) / powerNow
        elif status == "Discharging" or status == "Not charging":
          remTime = energyNow / powerNow
          flag = "↓"

      return &"{flag} {capacity}%:{remTime.int}H"
    except:
      return "battery: unknown"
  try:
    result = getBatteryInfoReal(devpath, useEnergyFullDesign)
  except:
    result = "battery: unknown"

proc get_status() =
  var
    width = getWidth().toFloat
    min_width = (width * 0.664).toInt
    dev = "CMB0"
    devpath = "/sys/class/power_supply/" & dev
    status_array: seq[string]
    count = 5
  for i in 0..module_count.toInt:
    status_array.add("")
  while true:
    var
      item_num = 0
      full_text = times.now().format("yyyy-MM-dd ddd HH:mm:ss")
      status_item = fmt"""{{"full_text": "{full_text}", "name" : "datetime", "align":"center", "min_width": {min_width}}}"""

    status_array[item_num] = status_item
    inc item_num

    if count >= 5:
      status_array[item_num] = fmt"""{{ "full_text": " cpu {getCpuUsage():02}% ", "name": "cpu" }}"""
      inc item_num
      status_array[item_num] = fmt"""{{ "full_text": " mem {getMemUsage():02}% ", "name": "mem" }}"""
      inc item_num
      var battery_info = getBatteryInfo(devpath, false)
      status_array[item_num] = fmt"""{{ "full_text": " {battery_info} ", "name": "battery" }}"""
      inc item_num
      count = 0

    var status_line = status_array.join(",")
    echo fmt"[{status_line}],"
    os.sleep(1*1000)
    inc count

get_status()
