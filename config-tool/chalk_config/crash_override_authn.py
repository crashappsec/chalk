import json
import jwt
import time
import requests

from .log import get_logger
logger = get_logger(__name__)

class CrashOverrideAuth:

    def __init__(self, auth_url):
        """
        """
        self.id       = ""
        self.device_id = self.id
        self.auth_url = auth_url
        self._nonce   = ""
        self.poll_url = ""
        self.poll_int = 5
        self._poll_issued_at = 0
        self._poll_expiration = 0
        self.auth_jwt = ""
        self.token    = ""
        self.token_issued_at = 0
        #self.token_expiration = 0
        self.authenticated = False
        self.failed   = False
        self.decoded_jwt = ""
        self._poll_decoded_jwt = ""
        self.revision_id = ""
        # User data available post-authN
        self.user_id    = ""
        self.user_name  = ""
        self.user_email = ""
        self.user_picture = "" 

    def _get_code(self):
        """
        """
        try:
            resp = requests.post(self.auth_url)
            resp_json = resp.json()  

            self.id       = resp_json["id"]
            self.auth_url = resp_json["authUrl"]
            self.poll_url = resp_json["pollUrl"]
            self.poll_int = resp_json["pollIntervalSeconds"]
            self._poll_jwt = self.poll_url.split("jwt=")[-1]
            self._poll_decoded_jwt = self._decode_and_validate_jwt(self._poll_jwt)
            self._poll_expiration = self._poll_decoded_jwt["exp"]
            self._poll_issued_at = self._poll_decoded_jwt["iat"]

            return resp_json

        except Exception as err:
            logger.error("[-] Error calling the config-tool code endpoint at %s: %s"%(self.auth_url, err))
            return None

    def _decode_and_validate_jwt(self, jwt_to_decode, validate = False, key = None):
        """

        """
        # Todo - validation
        if not validate:
            decoded_jwt = jwt.decode(jwt_to_decode, algorithms=["HS256"],  options={"verify_signature": False})
        else:
            logger.error("JWT validation not implemented yet, only symmetric supported atm")

        return decoded_jwt

    def _show_token(self):
        """
        """
        print("\nVisit %s to authenticate\n"%(self.auth_url))

    def _poll(self):
        """
        """
        while self.poll_int != 0:
            try:
                resp = requests.get(self.poll_url)

                # Successful authn - exit loop HTTP 428 vs 200
                if resp.status_code == 200:
                    # Retrieve token from the 200
                    resp_json = resp.json()
                    
                    # Decode JWT
                    self.token = resp_json["token"]
                    self.decoded_jwt = self._decode_and_validate_jwt(self.token)
                    self.revision_id = self.decoded_jwt["revisionId"]
                    self.token_issued_at = self.decoded_jwt["iat"]

                    # Populate authenticated user data (keep outside of token/jwt that is passed down to generated chalks)
                    self._user_json = resp_json["user"]
                    self.user_id = self._user_json["id"]
                    self.user_name = self._user_json["name"]
                    self.user_email = self._user_json["email"]
                    self.user_picture = self._user_json["picture"]
                    
                    self.authenticated = True
                    break

            except Exception as err:
                print("[-] Error calling the config-tool code endpoint at %s: %s"%(self.poll_url, err))
                return None

            # Authn pending - wait....
            time.sleep(int(self.poll_int))

    def authenticate(self):
        """
        Run a complete authentication flow to retrieve a JWT to authenticate to the API
        This JWT is embedded into the chalk binaries the config-tool generates
        """
        # Get code
        self._get_code()

        # Display URL to user self.auth_url

        # Poll for success
        self._poll()


if __name__ == "__main__":

    COA = CrashOverrideAuth()
    COA.authenticate()
    if COA.authenticated:
        print("Authentication successful")
    else:
        print("Authentication failed")

