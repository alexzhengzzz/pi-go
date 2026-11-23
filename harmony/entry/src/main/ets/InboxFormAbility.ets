import { Want } from '@kit.AbilityKit';
import { FormExtensionAbility, formBindingData, formInfo, formProvider } from '@kit.FormKit';
import { inboxFormData, registerInboxForm } from './InboxWidget';

export default class InboxFormAbility extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    const id = want.parameters?.[formInfo.FormParam.IDENTITY_KEY];
    const rawDim = want.parameters?.[formInfo.FormParam.DIMENSION_KEY];
    const dimension = typeof rawDim === 'number' ? rawDim : Number(rawDim) || 2;
    if (typeof id === 'string') {
      registerInboxForm(this.context, id, true, dimension);
      return inboxFormData(this.context, id, dimension);
    }
    return inboxFormData(this.context, undefined, dimension);
  }

  onUpdateForm(id: string): void {
    registerInboxForm(this.context, id, true);
    void formProvider.updateForm(id, inboxFormData(this.context, id)).catch((): void => {});
  }

  onRemoveForm(id: string): void {
    registerInboxForm(this.context, id, false);
  }
}
