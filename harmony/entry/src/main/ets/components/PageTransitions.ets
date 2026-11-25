export function pagePushTransition(): TransitionEffect {
  return TransitionEffect.asymmetric(
    TransitionEffect.move(TransitionEdge.END)
      .animation({ duration: 240, curve: Curve.FastOutSlowIn }),
    TransitionEffect.move(TransitionEdge.END)
      .animation({ duration: 200, curve: Curve.FastOutSlowIn })
  );
}

export function subPageTransition(): TransitionEffect {
  return TransitionEffect.asymmetric(
    TransitionEffect.OPACITY.combine(TransitionEffect.translate({ x: 24 }))
      .animation({ duration: 220, curve: Curve.FastOutSlowIn }),
    TransitionEffect.OPACITY
      .animation({ duration: 150, curve: Curve.EaseOut })
  );
}

export function parentPageTransition(): TransitionEffect {
  return TransitionEffect.asymmetric(
    TransitionEffect.OPACITY.combine(TransitionEffect.translate({ x: -16 }))
      .animation({ duration: 200, curve: Curve.FastOutSlowIn }),
    TransitionEffect.OPACITY
      .animation({ duration: 140, curve: Curve.EaseOut })
  );
}

export function drawerSlideTransition(): TransitionEffect {
  return TransitionEffect.asymmetric(
    TransitionEffect.move(TransitionEdge.START)
      .animation({ duration: 220, curve: Curve.FastOutSlowIn }),
    TransitionEffect.move(TransitionEdge.START)
      .animation({ duration: 180, curve: Curve.FastOutSlowIn })
  );
}

export function modalFadeTransition(): TransitionEffect {
  return TransitionEffect.asymmetric(
    TransitionEffect.OPACITY.animation({ duration: 180, curve: Curve.EaseOut }),
    TransitionEffect.OPACITY.animation({ duration: 150, curve: Curve.EaseIn })
  );
}

export function modalCardTransition(): TransitionEffect {
  return TransitionEffect.asymmetric(
    TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.94, y: 0.94 }))
      .animation({ duration: 200, curve: Curve.FastOutSlowIn }),
    TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.96, y: 0.96 }))
      .animation({ duration: 150, curve: Curve.EaseIn })
  );
}

export function bannerTransition(): TransitionEffect {
  return TransitionEffect.asymmetric(
    TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: -12 }))
      .animation({ duration: 200, curve: Curve.EaseOut }),
    TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: -8 }))
      .animation({ duration: 160, curve: Curve.EaseIn })
  );
}
