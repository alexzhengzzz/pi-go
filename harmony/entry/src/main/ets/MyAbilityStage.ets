import { AbilityStage, Want } from '@kit.AbilityKit';
import { entryInstances } from './EntryInstanceRegistry';

export default class MyAbilityStage extends AbilityStage {
  onAcceptWant(want: Want): string {
    if (want.abilityName === 'EntryAbility') {
      const key = entryInstances.acceptWant(want);
      console.info(`[PiGoMulti] onAcceptWant -> ${key} action=${want.action ?? ''}`);
      return key;
    }
    return '';
  }
}
