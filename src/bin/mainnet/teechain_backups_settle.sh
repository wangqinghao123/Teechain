#!/bin/bash
set -e

# Colour constants
bold=`tput bold`
green=`tput setaf 2`
red=`tput setaf 1`
reset=`tput sgr0`

ALICE_PORT=10001
ALICE_BACKUP_PORT_1=20001
ALICE_BACKUP_PORT_2=30001

BOB_PORT=10002
BOB_BACKUP_PORT_1=20002

ALICE_LOG=bin/mainnet/test/alice.txt
ALICE_BACKUP_LOG_1=bin/mainnet/test/alice_backup_1.txt
ALICE_BACKUP_LOG_2=bin/mainnet/test/alice_backup_2.txt

BOB_LOG=bin/mainnet/test/bob.txt
BOB_BACKUP_LOG_1=bin/mainnet/test/bob_backup_1.txt

if test -d bin; then cd bin; fi

echo "${bold}Mounting a RAM disk for server output in test directory!${reset}"
if mountpoint -q -- "test"; then
    sudo umount test
fi

rm -r test | true # in case this is the first time being run
mkdir test && sudo mount -t tmpfs -o size=5000m tmpfs test

# Source Intel Libraries
source /opt/intel/sgxsdk/environment

pushd ../../ # go to source directory
echo "${bold}Starting the ghost teechain enclaves...${reset}"

echo "${bold}Spawning enclave ALICE listening on port $ALICE_PORT in $ALICE_LOG ${reset}"
./teechain ghost -d -p $ALICE_PORT > $ALICE_LOG 2>&1 &
sleep 1

echo "${bold}Spawning enclave ALICE_BACKUP_1 listening on port $ALICE_BACKUP_1 in $ALICE_BACKUP_LOG_1 ${reset}"
./teechain ghost -d -p $ALICE_BACKUP_PORT_1 > $ALICE_BACKUP_LOG_1 2>&1 &
sleep 1

echo "${bold}Spawning enclave ALICE_BACKUP_2 listening on port $ALICE_BACKUP_2 in $ALICE_BACKUP_LOG_2 ${reset}"
./teechain ghost -d -p $ALICE_BACKUP_PORT_2 > $ALICE_BACKUP_LOG_2 2>&1 &
sleep 1

echo "${bold}Spawning enclave BOB listening on port $BOB_PORT in $BOB_LOG ${reset}"
./teechain ghost -d -p $BOB_PORT > $BOB_LOG 2>&1 &
sleep 1

echo "${bold}Spawning enclave BOB_BACKUP_1 listening on port $BOB_BACKUP_1 in $BOB_BACKUP_LOG_1 ${reset}"
./teechain ghost -d -p $BOB_BACKUP_PORT_1 > $BOB_BACKUP_LOG_1 2>&1 &
sleep 1

echo -n "${red}Waiting until enclaves are initialized ...!${reset}"
for u in alice alice_backup_1 alice_backup_2 bob bob_backup_1; do
    while [ "$(grep -a 'Enclave created' bin/mainnet/test/${u}.txt | wc -l)" -eq 0 ]; do
        sleep 0.1
        echo -n "."
    done
done

# Create primaries and backups
./teechain primary -p $ALICE_PORT
./teechain backup -p $ALICE_BACKUP_PORT_1
./teechain backup -p $ALICE_BACKUP_PORT_2

./teechain primary -p $BOB_PORT
./teechain backup -p $BOB_BACKUP_PORT_1

# Setup up primaries with number of deposits
./teechain setup_deposits 2 -p $ALICE_PORT
./teechain setup_deposits 1 -p $BOB_PORT

# Deposits made
./teechain deposits_made 1PxpP8fCsdjVrS187fP2byc5uYap3fA7j2 1 2 edec34c9bb3a4395cd8d1e9300725f537235d8a058fc6a7ae519003b64fd0feA 0 100 edec34c9bb3a4395cd8d1e9300725f537235d8a058fc6a7ae519003b64fd0feA 1 1000 -p $ALICE_PORT
./teechain deposits_made 1NqY7EC7Y5oZSMHos3CJxv1Z69BdkLZvWy 1 1 edec34c9bb3a4395cd8d1e9300725f537235d8a058fc6a7ae519003b64fd0feB 0 100 -p $BOB_PORT

# Create and establish a channel between Alice and Bob
./teechain create_channel -p $BOB_PORT &
sleep 1
./teechain create_channel -i -r 127.0.0.1:$BOB_PORT -p $ALICE_PORT # Initiator

sleep 2

# Extract the channel id for the channel created
CHANNEL_1=$(grep "Channel ID:" $ALICE_LOG | awk '{print $3}')
echo "Channel 1 ID is $CHANNEL_1"

# Assign backup to Alice
./teechain add_backup -p $ALICE_PORT &
sleep 1
./teechain add_backup -i -r 127.0.0.1:$ALICE_PORT -p $ALICE_BACKUP_PORT_1

sleep 2

# Extract the channel id for the channel created
ALICE_BACKUP_CHANNEL_1=$(grep "Backup Channel ID:" $ALICE_BACKUP_LOG_1 | awk '{print $4}')
echo "Backup Channel 1 ID is $ALICE_BACKUP_CHANNEL_1"

# Assign another backup to alice chain
./teechain add_backup -p $ALICE_BACKUP_PORT_1 &
sleep 1
./teechain add_backup -i -r 127.0.0.1:$ALICE_BACKUP_PORT_1 -p $ALICE_BACKUP_PORT_2

sleep 2

# Extract the channel id for the channel created
ALICE_BACKUP_CHANNEL_2=$(grep "Channel ID:" $ALICE_BACKUP_LOG_2 | awk '{print $4}')
echo "Backup Channel 2 ID is $ALICE_BACKUP_CHANNEL_2"

# Assign backup to Bob
./teechain add_backup -p $BOB_PORT &
sleep 1
./teechain add_backup -i -r 127.0.0.1:$BOB_PORT -p $BOB_BACKUP_PORT_1

sleep 2

# Extract the channel id for the channel created
BOB_BACKUP_CHANNEL_1=$(grep "Backup Channel ID:" $BOB_BACKUP_LOG_1 | awk '{print $4}')
echo "Backup Channel 3 ID is $BOB_BACKUP_CHANNEL_1"

# Verified the setup transactions are in the blockchain
./teechain verify_deposits $CHANNEL_1 -p $BOB_PORT &
./teechain verify_deposits $CHANNEL_1 -p $ALICE_PORT

sleep 2

# Alice check balance matches expected
./teechain balance $CHANNEL_1 -p $ALICE_PORT
if ! tail -n 4 $ALICE_LOG | grep -q "My balance is: 0, remote balance is: 0"; then
    echo "Alice's balance check failed on channel setup!"; exit 1;
fi

# Alice and Bob add deposits to their channels now
./teechain add_deposit $CHANNEL_1 0 -p $ALICE_PORT
./teechain add_deposit $CHANNEL_1 0 -p $BOB_PORT

# Alice check balance matches expected
./teechain balance $CHANNEL_1 -p $ALICE_PORT
if ! tail -n 4 $ALICE_LOG | grep -q "My balance is: 100, remote balance is: 100"; then
    echo "Alice's balance check failed on channel setup!"; exit 1;
fi

# Send from Bob to Alice
./teechain send $CHANNEL_1 1 -p $BOB_PORT

# Alice check balance after
./teechain balance $CHANNEL_1 -p $ALICE_PORT
if ! tail -n 4 $ALICE_LOG | grep -q "My balance is: 101, remote balance is: 99"; then
    echo "Alice's balance check failed after send!"; exit 1;
fi

# Send from Bob to Alice
./teechain send $CHANNEL_1 1 -p $BOB_PORT

# Bob check balance
./teechain balance $CHANNEL_1 -p $BOB_PORT
if ! tail -n 4 $BOB_LOG | grep -q "My balance is: 98, remote balance is: 102"; then
    echo "Bob's balance check failed after second send!"; exit 1;
fi

# Send from Alice to Bob
./teechain send $CHANNEL_1 50 -p $ALICE_PORT

# Bob check balance
./teechain balance $CHANNEL_1 -p $BOB_PORT
if ! tail -n 4 $BOB_LOG | grep -q "My balance is: 148, remote balance is: 52"; then
    echo "Bob's balance check failed after alice's send!"; exit 1;
fi

# Cannot return unused deposits from last node in Alice's chain
./teechain return_unused_deposits -p $ALICE_BACKUP_PORT_2
if ! tail -n 4 $ALICE_BACKUP_LOG_2 | grep -q "Cannot return unused deposits;"; then
    echo "Failed to prevent returning deposits through backup!"; exit 1;
fi

# Cannot settle channel last node in Alice's chain
./teechain settle_channel $CHANNEL_1 -p $ALICE_BACKUP_PORT_2
if ! tail -n 4 $ALICE_BACKUP_LOG_2 | grep -q "Cannot settle channel;"; then
    echo "Failed to prevent settling channel through backup!"; exit 1;
fi

# Expected tx to return deposit index 1
EXPECTED_RETURN_TX=0100000001ea0ffd643b0019e57a6afc58a0d83572535f7200931e8dcd95433abbc934eced0100000000ffffffff0109030000000000001976a914fbe1328227e643d7da2f81c9f4124effac1d709488ac00000000

# Return unused deposits from Alice
./teechain return_unused_deposits -p $ALICE_PORT
if ! tail -n 4 $ALICE_LOG | grep -q $EXPECTED_RETURN_TX; then
    echo "Failed to return deposit index 1 from Alice!"; exit 1;
fi
echo "Alice's returned the unused deposit"

# Add returned deposit and see it fail
./teechain add_deposit $CHANNEL_1 1 -p $ALICE_PORT
./teechain balance $CHANNEL_1 -p $ALICE_PORT
if ! tail -n 4 $ALICE_LOG | grep -q "My balance is: 52, remote balance is: 148"; then
    echo "Alice's balance check failed after trying to add invalid deposit!"; exit 1;
fi

EXPECTED_SETTLE=0100000002ea0ffd643b0019e57a6afc58a0d83572535f7200931e8dcd95433abbc934eced0000000000ffffffffeb0ffd643b0019e57a6afc58a0d83572535f7200931e8dcd95433abbc934eced0000000000ffffffff0234000000000000001976a914fbe1328227e643d7da2f81c9f4124effac1d709488ac94000000000000001976a914ef889322cc51ca6a1b31ef4564df90318431058988ac00000000

# Settle and shutdown
./teechain settle_channel $CHANNEL_1 -p $ALICE_PORT
if ! tail -n 4 $ALICE_LOG | grep -q $EXPECTED_SETTLE; then
    echo "Alice's channel wasn't settled!"; exit 1;
fi

# Alice decides to shutdown through backup
./teechain shutdown -p $ALICE_BACKUP_PORT_2
if ! tail -n 40 $ALICE_BACKUP_LOG_2 | grep -q $EXPECTED_RETURN_TX; then
    echo "Alice's unused deposits weren't returned!"; exit 1;
fi
if ! tail -n 40 $ALICE_BACKUP_LOG_2 | grep -q $EXPECTED_SETTLE; then
    echo "Alice's channel wasn't settled!"; exit 1;
fi

popd # return to bin directory

../kill.sh
echo "${bold}Looks like the test passed!${reset}"
