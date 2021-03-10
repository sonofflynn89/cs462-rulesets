import requests
import sys
import time

QUERY_BASE = 'http://localhost:8010/proxy/sky/cloud/'
QUERY_URL = QUERY_BASE + 'cklmw958m002b8wvl23co7fpl'
EVENT_BASE = 'http://localhost:8010/proxy/sky/event/'
EVENT_URL = EVENT_BASE +'cklmw958m002b8wvl23co7fpl/test-harness'

# Wipe Sensors
requests.post(EVENT_URL + '/test/sensors_unneeded')

# Create Sensors
print('Creating Sensors...')
requests.post(EVENT_URL + '/sensor/new_sensor', {'sensor_name': 'Wovyn 1'})
requests.post(EVENT_URL + '/sensor/new_sensor', {'sensor_name': 'Wovyn 3'})
time.sleep(1)

# Verify Creation
response = requests.post(QUERY_URL + '/manage_sensors/sensors')
sensors = response.json()
if not ('Wovyn 1' in sensors) or not ('Wovyn 3' in sensors):
    print('Error: Sensors Not Created')
    sys.exit()
else:
    print('Sensors Created Successfully')

# Verify Sensor Profiles
print('Verifying Sensor Profiles...')
response = requests.post(QUERY_URL + '/manage_sensors/sensor_profiles')
sensor_profiles = response.json()
for i, s in enumerate(["Wovyn 1", 'Wovyn 3']):
    if sensor_profiles[s]["name"] != s:
        print("Error: Sensor Profile Name Not Set")
        sys.exit()
    if sensor_profiles[s]["threshold"] != 70:
        print("Error: Sensor Profile Threshold Not Set")
        sys.exit()

print("Sensor Profiles Configured Correctly")

# Send Fake Readings
print("Sending Fake Readings to 'Wovyn 1' and 'Wovyn 3'...")
requests.post(EVENT_URL + '/test/new_reading', {'sensor_name': 'Wovyn 1', 'temperature': 9001})
requests.post(EVENT_URL + '/test/new_reading', {'sensor_name': 'Wovyn 3', 'temperature': 9003})

# Verify That Fake Readings Were Received
time.sleep(3)
response = requests.post(QUERY_URL + '/manage_sensors/all_temperatures')
temperatures_by_sensor = response.json()

wovyn_1_received = False
for index, item in enumerate(temperatures_by_sensor[0]):
    if item["temperature"] == 9001:
        wovyn_1_received = True

if not wovyn_1_received:
    print('Error: Wovyn 1 did not receive fake reading')
    sys.exit()

wovyn_3_received = False
for index, item in enumerate(temperatures_by_sensor[1]):
    if item["temperature"] == 9003:
        wovyn_3_received = True

if not wovyn_3_received:
    print('Error: Wovyn 3 did not receive fake reading')
    sys.exit()

print('Wovyn 1 and Wovyn 3 Received Fake Readings')





