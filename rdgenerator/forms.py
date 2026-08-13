from django import forms
from django.core.cache import cache
from PIL import Image
import re
import requests


FALLBACK_RUSTDESK_VERSIONS = [
    '1.4.9', '1.4.8', '1.4.7', '1.4.6', '1.4.5',
    '1.4.4', '1.4.3', '1.4.2', '1.4.1', '1.4.0',
]
RUSTDESK_RELEASES_URL = 'https://api.github.com/repos/rustdesk/rustdesk/releases?per_page=100'
RUSTDESK_VERSION_CACHE_KEY = 'rustdesk-stable-version-choices-v1'
SEMVER_TAG = re.compile(r'^\d+\.\d+\.\d+$')


def get_rustdesk_version_choices():
    cached = cache.get(RUSTDESK_VERSION_CACHE_KEY)
    if cached:
        return cached

    discovered = []
    try:
        response = requests.get(
            RUSTDESK_RELEASES_URL,
            headers={
                'Accept': 'application/vnd.github+json',
                'User-Agent': 'RDGen-version-selector',
            },
            timeout=3,
        )
        response.raise_for_status()
        releases = response.json()
        if not isinstance(releases, list):
            raise ValueError('Unexpected GitHub releases response')
        discovered = [
            release.get('tag_name', '')
            for release in releases
            if isinstance(release, dict)
            if not release.get('draft')
            and not release.get('prerelease')
            and SEMVER_TAG.fullmatch(release.get('tag_name', ''))
        ]
    except (requests.RequestException, ValueError, TypeError):
        # The generator must remain usable if GitHub is temporarily unavailable.
        pass

    versions = set(discovered)
    versions.update(FALLBACK_RUSTDESK_VERSIONS)
    ordered_versions = sorted(
        versions,
        key=lambda version: tuple(int(part) for part in version.split('.')),
        reverse=True,
    )
    choices = [('master', 'nightly')] + [
        (version, version) for version in ordered_versions[:10]
    ]
    cache.set(RUSTDESK_VERSION_CACHE_KEY, choices, 60 * 60)
    return choices

class GenerateForm(forms.Form):
    sh_secret_field = forms.CharField(required=False)
    #Platform
    platform = forms.ChoiceField(choices=[('windows','Windows 64Bit'),('windows-x86','Windows 32Bit'),('linux','Linux'),('android','Android'),('macos','macOS')], initial='windows')
    version = forms.ChoiceField(choices=[('master', 'nightly')], initial='1.4.9')
    help_text="'master' is the development version (nightly build) with the latest features but may be less stable"
    delayFix = forms.BooleanField(initial=True, required=False)
    telegramNotifications = forms.BooleanField(initial=False, required=False)

    #General
    exename = forms.CharField(label="Name for EXE file", required=True)
    primarySuffix = forms.CharField(label="File suffix for primary client", required=False)
    appname = forms.CharField(label="Custom App Name", required=False)
    direction = forms.MultipleChoiceField(widget=forms.CheckboxSelectMultiple, choices=[
        ('incoming', 'Incoming Quick Client'),
        ('outgoing', 'Outgoing Quick Client'),
        ('both', 'Full Bidirectional Client')
    ], initial=['incoming', 'outgoing', 'both'])
    installation = forms.ChoiceField(label="Disable Installation", choices=[
        ('installationY', 'No, enable installation'),
        ('installationN', 'Yes, DISABLE installation')
    ], initial='installationY')
    settings = forms.ChoiceField(label="Disable Settings", choices=[
        ('settingsY', 'No, enable settings'),
        ('settingsN', 'Yes, DISABLE settings')
    ], initial='settingsY')
    androidappid = forms.CharField(label="Custom Android App ID (replaces 'com.carriez.flutter_hbb')", required=False)

    #Custom Server
    serverIP = forms.CharField(label="Host", required=False)
    apiServer = forms.CharField(label="API Server", required=False)
    key = forms.CharField(label="Key", required=False)
    urlLink = forms.CharField(label="Custom URL for links", required=False)
    downloadLink = forms.CharField(label="Custom URL for downloading new versions", required=False)
    compname = forms.CharField(label="Company name",required=False)

    #Visual
    iconfile = forms.FileField(label="Custom App Icon (in .png format)", required=False, widget=forms.FileInput(attrs={'accept': 'image/png'}))
    logofile = forms.FileField(label="Custom App Logo (in .png format)", required=False, widget=forms.FileInput(attrs={'accept': 'image/png'}))
    privacyfile = forms.FileField(label="Custom privacy screen (in .png format)", required=False, widget=forms.FileInput(attrs={'accept': 'image/png'}))
    iconbase64 = forms.CharField(required=False)
    logobase64 = forms.CharField(required=False)
    privacybase64 = forms.CharField(required=False)
    theme = forms.ChoiceField(choices=[
        ('light', 'Light'),
        ('dark', 'Dark'),
        ('system', 'Follow System')
    ], initial='system')
    themeDorO = forms.ChoiceField(choices=[('default', 'Default'),('override', 'Override')], initial='default')

    #Security
    passApproveMode = forms.ChoiceField(choices=[('password','Accept sessions via password'),('click','Accept sessions via click'),('password-click','Accepts sessions via both')],initial='password-click')
    permanentPassword = forms.CharField(widget=forms.PasswordInput(), required=False)
    #runasadmin = forms.ChoiceField(choices=[('false','No'),('true','Yes')], initial='false')
    denyLan = forms.BooleanField(initial=False, required=False)
    enableDirectIP = forms.BooleanField(initial=False, required=False)
    #ipWhitelist = forms.BooleanField(initial=False, required=False)
    autoClose = forms.BooleanField(initial=False, required=False)

    #Permissions
    permissionsDorO = forms.ChoiceField(choices=[('default', 'Default'),('override', 'Override')], initial='default')
    permissionsType = forms.ChoiceField(choices=[('custom', 'Custom'),('full', 'Full Access'),('view','Screen share')], initial='custom')
    enableKeyboard =  forms.BooleanField(initial=True, required=False)
    enableClipboard = forms.BooleanField(initial=True, required=False)
    enableFileTransfer = forms.BooleanField(initial=True, required=False)
    enableAudio = forms.BooleanField(initial=True, required=False)
    enableTCP = forms.BooleanField(initial=True, required=False)
    enableRemoteRestart = forms.BooleanField(initial=True, required=False)
    enableRecording = forms.BooleanField(initial=True, required=False)
    enableBlockingInput = forms.BooleanField(initial=True, required=False)
    enableRemoteModi = forms.BooleanField(initial=False, required=False)
    hidecm = forms.BooleanField(initial=False, required=False)
    enablePrinter = forms.BooleanField(initial=True, required=False)
    enableCamera = forms.BooleanField(initial=True, required=False)
    enableTerminal = forms.BooleanField(initial=True, required=False)

    #Other
    removeWallpaper = forms.BooleanField(initial=True, required=False)

    defaultManual = forms.CharField(widget=forms.Textarea, required=False)
    overrideManual = forms.CharField(widget=forms.Textarea, required=False)

    #custom added features
    xOffline = forms.BooleanField(initial=False, required=False)
    removeNewVersionNotif = forms.BooleanField(initial=False, required=False)

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        choices = get_rustdesk_version_choices()
        self.fields['version'].choices = choices
        stable_versions = [value for value, _label in choices if value != 'master']
        if stable_versions:
            self.fields['version'].initial = stable_versions[0]

    def clean_iconfile(self):
        print("checking icon")
        image = self.cleaned_data['iconfile']
        if image:
            try:
                # Open the image using Pillow
                img = Image.open(image)

                # Check if the image is a PNG (optional, but good practice)
                if img.format != 'PNG':
                    raise forms.ValidationError("Only PNG images are allowed.")

                # Get image dimensions
                width, height = img.size

                # Check for square dimensions
                if width != height:
                    raise forms.ValidationError("Custom App Icon dimensions must be square.")
                
                return image
            except OSError:  # Handle cases where the uploaded file is not a valid image
                raise forms.ValidationError("Invalid icon file.")
            except Exception as e: # Catch any other image processing errors
                raise forms.ValidationError(f"Error processing icon: {e}")
