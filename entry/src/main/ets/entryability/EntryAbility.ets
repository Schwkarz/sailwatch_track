import { AbilityConstant, ConfigurationConstant, errorManager, UIAbility, Want } from '@kit.AbilityKit';
import { hiAppEvent, hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { diagnosticLogStore } from '../utils/diagnosticLogStore';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  private readonly globalErrorObserver: errorManager.GlobalObserver =
    (reason: errorManager.GlobalError): void => {
      diagnosticLogStore.error('ARK_RUNTIME',
        `type=global_error,instanceName=${reason.instanceName},instanceType=${reason.instanceType},` +
        `name=${reason.name},message=${reason.message},stack=${reason.stack}`);
    };

  private readonly globalRejectionObserver: errorManager.GlobalObserver =
    (reason: errorManager.GlobalError): void => {
      diagnosticLogStore.error('ARK_RUNTIME',
        `type=unhandled_rejection,instanceName=${reason.instanceName},instanceType=${reason.instanceType},` +
        `name=${reason.name},message=${reason.message},stack=${reason.stack}`);
    };

  private readonly freezeObserver: errorManager.FreezeObserver = (): void => {
    diagnosticLogStore.error('ARK_RUNTIME', 'type=freeze_observer_called');
  };

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      diagnosticLogStore.setup(this.context.filesDir);
      diagnosticLogStore.recordLifecycle('ability_on_create');
    } catch (error) {
      hilog.error(DOMAIN, 'SailWatchDiag', 'Failed to initialize diagnostics: %{public}s', JSON.stringify(error));
    }
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (error) {
      diagnosticLogStore.error('APP_LIFECYCLE', `setColorMode failed error=${JSON.stringify(error)}`);
    }
    this.registerRuntimeErrorObservers();
    this.registerSystemEventWatchers();
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    diagnosticLogStore.recordLifecycle('ability_on_destroy_called',
      `monitoringActive=${diagnosticLogStore.isMonitoringActive()}`);
    diagnosticLogStore.markAbilityDestroyed();
    this.unregisterRuntimeErrorObservers();
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');
    diagnosticLogStore.recordLifecycle('window_stage_create');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        diagnosticLogStore.error('APP_LIFECYCLE', `loadContent failed error=${JSON.stringify(err)}`);
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
      diagnosticLogStore.recordLifecycle('window_content_loaded');
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
    diagnosticLogStore.recordLifecycle('window_stage_destroy',
      `monitoringActive=${diagnosticLogStore.isMonitoringActive()}`);
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
    diagnosticLogStore.recordLifecycle('ability_foreground',
      `monitoringActive=${diagnosticLogStore.isMonitoringActive()}`);
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
    diagnosticLogStore.recordLifecycle('ability_background',
      `monitoringActive=${diagnosticLogStore.isMonitoringActive()}`);
  }

  private registerSystemEventWatchers(): void {
    try {
      const faultWatcher: hiAppEvent.Watcher = {
        name: 'sailwatch_faults',
        appEventFilters: [
          {
            domain: hiAppEvent.domain.OS,
            names: [
              hiAppEvent.event.APP_CRASH,
              hiAppEvent.event.APP_FREEZE,
              hiAppEvent.event.MAIN_THREAD_JANK,
              hiAppEvent.event.RESOURCE_OVERLIMIT,
              hiAppEvent.event.CPU_USAGE_HIGH
            ]
          }
        ],
        onReceive: (domain: string, appEventGroups: Array<hiAppEvent.AppEventGroup>): void => {
          this.handleSystemEvents(domain, appEventGroups);
        }
      };
      hiAppEvent.addWatcher(faultWatcher);
      diagnosticLogStore.info('SYSTEM_EVENT', 'fault watcher registered');
    } catch (error) {
      diagnosticLogStore.error('SYSTEM_EVENT', `fault watcher registration failed error=${JSON.stringify(error)}`);
    }

    // APP_KILLED was added in API 20. A literal name keeps this API 18 project compilable;
    // newer watches can report the exact system kill reason, while older watches simply provide no callback.
    try {
      const killedWatcher: hiAppEvent.Watcher = {
        name: 'sailwatch_app_killed',
        appEventFilters: [
          {
            domain: hiAppEvent.domain.OS,
            names: ['APP_KILLED']
          }
        ],
        onReceive: (domain: string, appEventGroups: Array<hiAppEvent.AppEventGroup>): void => {
          this.handleSystemEvents(domain, appEventGroups);
        }
      };
      hiAppEvent.addWatcher(killedWatcher);
      diagnosticLogStore.info('SYSTEM_EVENT', 'APP_KILLED watcher registered; callback requires OS API 20+');
    } catch (error) {
      diagnosticLogStore.warn('SYSTEM_EVENT',
        `APP_KILLED watcher unavailable on this system error=${JSON.stringify(error)}`);
    }
  }

  private registerRuntimeErrorObservers(): void {
    try {
      errorManager.on('globalErrorOccurred', this.globalErrorObserver);
      errorManager.on('globalUnhandledRejectionDetected', this.globalRejectionObserver);
      errorManager.on('freeze', this.freezeObserver);
      diagnosticLogStore.info('ARK_RUNTIME', 'global error, rejection and freeze observers registered');
    } catch (error) {
      diagnosticLogStore.error('ARK_RUNTIME', `observer registration failed error=${JSON.stringify(error)}`);
    }
  }

  private unregisterRuntimeErrorObservers(): void {
    try {
      errorManager.off('globalErrorOccurred', this.globalErrorObserver);
      errorManager.off('globalUnhandledRejectionDetected', this.globalRejectionObserver);
      errorManager.off('freeze', this.freezeObserver);
    } catch (error) {
      diagnosticLogStore.warn('ARK_RUNTIME', `observer removal failed error=${JSON.stringify(error)}`);
    }
  }

  private handleSystemEvents(domain: string, appEventGroups: Array<hiAppEvent.AppEventGroup>): void {
    diagnosticLogStore.info('SYSTEM_EVENT', `received domain=${domain},groups=${appEventGroups.length}`);
    for (const eventGroup of appEventGroups) {
      for (const eventInfo of eventGroup.appEventInfos) {
        try {
          diagnosticLogStore.recordSystemEvent(eventInfo.name, JSON.stringify(eventInfo.params));
        } catch (error) {
          diagnosticLogStore.error('SYSTEM_EVENT',
            `failed to persist event group=${eventGroup.name} error=${JSON.stringify(error)}`);
        }
      }
    }
  }
}
