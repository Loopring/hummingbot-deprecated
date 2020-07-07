![Hummingbot](https://i.ibb.co/X5zNkKw/blacklogo-with-text.png)

## NOTES

This is a special Hummingbot which has loopring DEX gateway support. The loopring gateway is now actively developed/maintained by a third party.
The main purpose of this special Hummingbot version is supporting the liquid mining in loopring DEX.
You can join the liquid mining pretty easy by typing a few setup instructions, see `RUNNING` section below.

HAPPY MINNING :)

## RUNNING

1. The code can be built to a docker container from the project folder with:
`docker build --pull --rm -f "Dockerfile" -t loopring:latest "."`

2. Launch the built image running bash
`docker run -it loopring:latest bash`

3. Run hummingbot with the loopring connector by then running this in the containers:
`/opt/conda/envs/loopring-hb/bin/python3 bin/hummingbot_quickstart.py`

4. You can test the hummingbot connector by then running the following hummingbot command:
`connect loopring`
And then entering the requested information from a loopring account

5. Run `pure_market_making` strategy and specify your parameters.

## REFERENCES

For Detailed Hummingbot help, please refer to Hummingbot project homepage https://github.com/CoinAlpha/hummingbot.

For loopring DEX help, please refer to <https://loopring.io/>. At least you need to sign up and get exported API key and secret key. To learn deailed description of these keys and loopring DEX API, please refer to <https://docs.loopring.io/en/>.