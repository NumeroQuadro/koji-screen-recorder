# First Launch Checklist — Kōji

Reset onboarding:

```bash
defaults delete com.koji.screenrecorder hasCompletedOnboarding || true
```

## Checklist

- [ ] Onboarding window appears on first launch
- [ ] Welcome step shows correctly
- [ ] Screen Recording permission step triggers OS dialog
- [ ] Microphone permission step works (enable and skip paths)
- [ ] "Ready" step closes onboarding and shows menu bar icon
- [ ] Second launch does NOT show onboarding
- [ ] Re-triggering from Settings works
